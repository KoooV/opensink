import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_util';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:platform_web/platform_web.dart';
import 'package:core_domain/core_domain.dart';
import 'package:web/web.dart';
import '../../core_crypto/test/key_store/secure_key_store_contract.dart';

int _webDbCounter = 0;

SecureKeyStore _webFactory({String? dbName}) =>
    WebSecureKeyStoreImpl(
      dbName: dbName ?? 'opensink_ks_web_test_${_webDbCounter++}',
    );

IdentityBundle _bundle({
  String publicKey = 'pk-web',
  List<int>? privateSeed,
  int createdAt = 1000,
}) =>
    IdentityBundle(
      userId: const UserId('user-web'),
      publicKey: publicKey,
      privateSeed: privateSeed ?? [1, 2, 3],
      createdAt: createdAt,
    );

T okValue<T, E>(Result<T, E> result) {
  expect(result.isOk, isTrue, reason: 'expected Ok, got $result');
  return (result as Ok<T, E>).value;
}

E errValue<T, E>(Result<T, E> result) {
  expect(result.isErr, isTrue, reason: 'expected Err, got $result');
  return (result as Err<T, E>).error;
}

Future<T> _idbRequest<T>(IDBRequest request, T Function(dynamic) extract) {
  final completer = Completer<T>();
  request.onsuccess = ((Event _) {
    if (!completer.isCompleted) {
      completer.complete(extract(request.result));
    }
  }).toJS;
  request.onerror = ((Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        request.error ?? StateError('IndexedDB request failed'),
      );
    }
  }).toJS;
  return completer.future;
}

/// Прямой доступ к IndexedDB из теста для манипуляций с записями
/// (подмена blob, порча IV/ciphertext).
Future<Map<String, dynamic>?> _readIdentityRaw(String dbName, UserId userId) async {
  final request = window.indexedDB.open(dbName, 1);
  final db = await _idbRequest(request, (r) => r as IDBDatabase);
  try {
    final stores = JSArray<JSString>()..add('identities'.toJS);
    final tx = db.transaction(stores, 'readonly');
    final store = tx.objectStore('identities');
    final getReq = store.get('identity_${userId.value}'.toJS);
    final value = await _idbRequest(getReq, (r) => r);
    if (value == null) return null;
    return jsonDecode(value as String) as Map<String, dynamic>;
  } finally {
    db.close();
  }
}

Future<void> _writeIdentityRaw(
  String dbName,
  UserId userId,
  Map<String, dynamic> value,
) async {
  final request = window.indexedDB.open(dbName, 1);
  final db = await _idbRequest(request, (r) => r as IDBDatabase);
  try {
    final stores = JSArray<JSString>()..add('identities'.toJS);
    final tx = db.transaction(stores, 'readwrite');
    final store = tx.objectStore('identities');
    await _idbRequest(
      store.put(jsify(value), 'identity_${userId.value}'.toJS),
      (_) {},
    );
  } finally {
    db.close();
  }
}

void main() {
  group('WebSecureKeyStoreImpl (Chrome, IndexedDB + Web Crypto API)', () {
    late SecureKeyStore store;

    const userId = UserId('user-web');

    setUp(() {
      store = _webFactory();
    });

    // --- Общий контракт ---

    test('запускает общий контракт SecureKeyStore', () async {
      runSecureKeyStoreContract(_webFactory, label: ' (Web)');
    });

    // --- Конкурентный getOrCreateKek (защита от гонки вкладок) ---

    test(
      'два экземпляра с одной БД создают один и тот же KEK, данные не теряются',
      () async {
        final dbName = 'opensink_ks_race_test_${_webDbCounter++}';
        final storeA = _webFactory(dbName: dbName);
        final storeB = _webFactory(dbName: dbName);

        // Оба пишут разные идентичности под разными userId.
        final bundleA = _bundle(publicKey: 'pk-a', privateSeed: [1, 2, 3]);
        final bundleB = _bundle(publicKey: 'pk-b', privateSeed: [4, 5, 6]);
        final userA = UserId('user-a');
        final userB = UserId('user-b');

        final writeA = await storeA.storeIdentity(userA, bundleA);
        final writeB = await storeB.storeIdentity(userB, bundleB);
        expect(writeA.isOk, isTrue);
        expect(writeB.isOk, isTrue);

        // Оба экземпляра должны иметь возможность расшифровать свои данные
        // (KEK общий, один на всю БД).
        final loadedA = okValue(await storeA.loadIdentity(userA));
        final loadedB = okValue(await storeB.loadIdentity(userB));
        expect(loadedA, equals(bundleA));
        expect(loadedB, equals(bundleB));

        // Перекрестная проверка: storeA может прочитать данные, записанные storeB,
        // и наоборот — подтверждает, что KEK один и тот же.
        final crossA = okValue(await storeA.loadIdentity(userB));
        final crossB = okValue(await storeB.loadIdentity(userA));
        expect(crossA, equals(bundleB));
        expect(crossB, equals(bundleA));
      },
    );

    // --- Подмена blob под другим именем (AAD) ---

    test(
      'подмена зашифрованного blob под другим именем ключа → StoreCorrupted',
      () async {
        final dbName = 'opensink_ks_alias_test_${_webDbCounter++}';
        final store = _webFactory(dbName: dbName);

        const targetUserId = UserId('user-target');
        const aliasUserId = UserId('user-alias');

        // Пишем под targetUserId.
        await store.storeIdentity(targetUserId, _bundle());

        // Читаем сырую запись и подменяем её под aliasUserId (той же зашифрованной
        // пакетой, но с другим ключом в IndexedDB). AAD = имя ключа, поэтому
        // расшифровка с чужым AAD должна упасть.
        final raw = await _readIdentityRaw(dbName, targetUserId);
        expect(raw, isNotNull);
        await _writeIdentityRaw(dbName, aliasUserId, raw!);

        // loadIdentity под aliasUserId должен вернуть StoreCorrupted.
        final result = await store.loadIdentity(aliasUserId);
        expect(result.isErr, isTrue);
        final err = errValue(result);
        expect(err, isA<StoreCorrupted>());
      },
    );

    // --- Порча IV / ciphertext ---

    test(
      'порча IV или ciphertext → StoreCorrupted',
      () async {
        final dbName = 'opensink_ks_tamper_test_${_webDbCounter++}';
        final store = _webFactory(dbName: dbName);

        await store.storeIdentity(userId, _bundle());

        final raw = await _readIdentityRaw(dbName, userId);
        expect(raw, isNotNull);

        // Портим IV (меняем последний байт base64-строки — это сломает декодирование
        // или расшифровку).
        final tampered = Map<String, dynamic>.from(raw!);
        final ivB64 = tampered['iv'] as String;
        tampered['iv'] =
            ivB64.replaceFirst(ivB64[ivB64.length - 1], 'A');
        await _writeIdentityRaw(dbName, userId, tampered);

        final result = await store.loadIdentity(userId);
        expect(result.isErr, isTrue);
        final err = errValue(result);
        expect(err, isA<StoreCorrupted>());
      },
    );

    // --- Переоткрытие хранилища ---

    test(
      'новый экземпляр с той же БД читает ранее сохранённые данные',
      () async {
        final dbName = 'opensink_ks_reopen_test_${_webDbCounter++}';
        final bundle = _bundle(privateSeed: [42, 43, 44]);

        final store1 = _webFactory(dbName: dbName);
        await store1.storeIdentity(userId, bundle);
        expect(okValue(await store1.hasIdentity(userId)), isTrue);

        // Новый экземпляр — как бы другая вкладка / перезагрузка страницы.
        final store2 = _webFactory(dbName: dbName);
        expect(okValue(await store2.hasIdentity(userId)), isTrue);
        final loaded = okValue(await store2.loadIdentity(userId));
        expect(loaded, equals(bundle));
      },
    );

    // --- Отсутствие ключа ---

    test('отсутствующий ключ: hasIdentity false, loadIdentity IdentityNotFound', () async {
      expect(okValue(await store.hasIdentity(userId)), isFalse);
      final err = errValue(await store.loadIdentity(userId));
      expect(err, isA<IdentityNotFound>());
    });
  });
}
