import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart';
import 'package:core_domain/core_domain.dart';

/// SecureKeyStore для Web: Web Crypto API + IndexedDB через [package:web].
///
/// Дизайн (см. DESIGN.md §12):
/// - KEK — AES-GCM-256 `CryptoKey` с `extractable: false`, хранится в
///   IndexedDB (хранилище `keys`). Сырой ключ KEK не попадает в дамп в aberto.
/// - При `storeIdentity` `IdentityBundle` сериализуется в JSON, шифруется
///   AES-GCM (случайный IV) ключом KEK, пара `{iv, ciphertext}` сохраняется
///   в хранилище `identities`.
/// - При `loadIdentity` запись расшифровывается KEK и десериализуется.
///
/// Ограничения (честная оценка, см. DESIGN.md §2, таблица угроз):
/// - Защищает от чтения дампа IndexedDB (KEK не извлекается).
/// - Не защищает от XSS: JS с правом выполнения может использовать KEK через
///   Web Crypto API.
/// - Неизвлекаемость самого identity-ключа (Ed25519/X25519) на web
///   недостижима, так как подпись выполняется в Dart над расшифрованным в
///   памяти ключом.
/// - Персистентность не гарантирована без `storage.persist()`.
class WebSecureKeyStoreImpl implements SecureKeyStore {
  WebSecureKeyStoreImpl({this.dbName = 'opensink_keystore'});

  final String dbName;

  IDBDatabase? _db;
  CryptoKey? _kek;

  static const _kekStore = 'keys';
  static const _identitiesStore = 'identities';
  static const _kekKey = 'opensink_kek';

  Future<IDBDatabase> get _database async {
    _db ??= await _openDb();
    return _db!;
  }

  Future<IDBDatabase> _openDb() {
    final idb = window.indexedDB;
    final completer = Completer<IDBDatabase>();
    final request = idb.open(dbName, 1);
    request.onupgradeneeded = ((Event _) {
      final db = request.result as IDBDatabase;
      if (!db.objectStoreNames.contains(_kekStore)) {
        db.createObjectStore(_kekStore);
      }
      if (!db.objectStoreNames.contains(_identitiesStore)) {
        db.createObjectStore(_identitiesStore);
      }
    }).toJS;
    request.onsuccess = ((Event _) {
      completer.complete(request.result as IDBDatabase);
    }).toJS;
    request.onerror = ((Event _) {
      completer.completeError(
        request.error ?? StateError('Не удалось открыть IndexedDB'),
      );
    }).toJS;
    return completer.future;
  }

  Future<CryptoKey> _getOrCreateKek() async {
    if (_kek != null) return _kek!;
    final db = await _database;
    final stores = JSArray<JSString>()..add(_kekStore.toJS);
    final tx = db.transaction(stores, 'readonly');
    final store = tx.objectStore(_kekStore);
    final existing = await _futureFromRequest(store.get(_kekKey.toJS), (r) => r);
    if (existing is CryptoKey) {
      _kek = existing;
      return _kek!;
    }
    final kek = await _generateKek();
    _kek = kek;
    await _put(_kekStore, _kekKey.toJS, kek);
    return kek;
  }

  Future<CryptoKey> _generateKek() async {
    final subtle = window.crypto.subtle;
    final promise = subtle.generateKey(
      AesKeyGenParams(length: 256),
      false,
      JSArray<JSString>()..add('encrypt'.toJS)..add('decrypt'.toJS),
    );
    final result = await promise.toDart;
    return result as CryptoKey;
  }

  @override
  Future<Result<void, KeyStoreError>> storeIdentity(
    UserId userId,
    IdentityBundle bundle,
  ) async {
    try {
      final kek = await _getOrCreateKek();
      final identityJson = jsonEncode({
        'userId': bundle.userId.value,
        'publicKey': bundle.publicKey,
        'privateSeed': base64Encode(bundle.privateSeed),
        'createdAt': bundle.createdAt,
      });
      final plaintext = utf8.encode(identityJson);
      final iv = Uint8List(12);
      window.crypto.getRandomValues(iv.toJS);
      final encryptPromise = window.crypto.subtle.encrypt(
        AesGcmParams(iv: iv.toJS),
        kek,
        plaintext.toJS,
      );
      final encrypted = await encryptPromise.toDart;
      final ciphertext = JSUint8Array(encrypted as JSArrayBuffer).toDart;
      await _put(
        _identitiesStore,
        _identityKey(userId).toJS,
        jsonEncode({
          'iv': base64Encode(iv),
          'ciphertext': base64Encode(ciphertext),
        }).toJS,
      );
      return const Ok(null);
    } catch (e, stack) {
      return Err(
        StoreError('Не удалось сохранить идентичность в IndexedDB: $e\n$stack'),
      );
    }
  }

  @override
  Future<Result<IdentityBundle, KeyStoreError>> loadIdentity(
    UserId userId,
  ) async {
    try {
      final kek = await _getOrCreateKek();
      final packed = await _get(_identitiesStore, _identityKey(userId).toJS);
      if (packed == null) {
        return const Err(IdentityNotFound());
      }
      final map = jsonDecode(packed as String) as Map<String, dynamic>;
      final iv = base64Decode(map['iv'] as String);
      final ciphertext = base64Decode(map['ciphertext'] as String);
      final decryptPromise = window.crypto.subtle.decrypt(
        AesGcmParams(iv: iv.toJS),
        kek,
        ciphertext.toJS,
      );
      final decrypted = await decryptPromise.toDart;
      final plaintext = JSUint8Array(decrypted as JSArrayBuffer).toDart;
      final identityJson = utf8.decode(plaintext);
      final identityMap =
          jsonDecode(identityJson) as Map<String, dynamic>;
      return Ok(
        IdentityBundle(
          userId: UserId(identityMap['userId'] as String),
          publicKey: identityMap['publicKey'] as String,
          privateSeed:
              base64Decode(identityMap['privateSeed'] as String),
          createdAt: identityMap['createdAt'] as int,
        ),
      );
    } catch (e, stack) {
      return Err(
        StoreError('Не удалось загрузить идентичность из IndexedDB: $e\n$stack'),
      );
    }
  }

  @override
  Future<Result<void, KeyStoreError>> deleteIdentity(UserId userId) async {
    try {
    final db = await _database;
    final stores = JSArray<JSString>()..add(_identitiesStore.toJS);
    final tx = db.transaction(stores, 'readwrite');
    final store = tx.objectStore(_identitiesStore);
      await _futureFromRequest(
        store.delete(_identityKey(userId).toJS),
        (_) => null,
      );
      return const Ok(null);
    } catch (e, stack) {
      return Err(
        StoreError('Не удалось удалить идентичность из IndexedDB: $e\n$stack'),
      );
    }
  }

  @override
  Future<Result<bool, KeyStoreError>> hasIdentity(UserId userId) async {
    try {
      final value = await _get(_identitiesStore, _identityKey(userId).toJS);
      return Ok(value != null);
    } catch (e, stack) {
      return Err(
        StoreError(
          'Не удалось проверить наличие идентичности в IndexedDB: $e\n$stack',
        ),
      );
    }
  }

  String _identityKey(UserId userId) => 'identity_${userId.value}';

  Future<JSAny?> _get(String storeName, JSAny? key) {
    final db = _database;
    return db.then((database) {
      final stores = JSArray<JSString>()..add(storeName.toJS);
      final tx = database.transaction(stores, 'readonly');
      final store = tx.objectStore(storeName);
      return _futureFromRequest(store.get(key), (r) => r);
    });
  }

  Future<void> _put(String storeName, JSAny? key, JSAny? value) {
    final db = _database;
    return db.then((database) {
      final stores = JSArray<JSString>()..add(storeName.toJS);
      final tx = database.transaction(stores, 'readwrite');
      final store = tx.objectStore(storeName);
      return _futureFromRequest(store.put(value, key), (_) {});
    });
  }

  Future<T> _futureFromRequest<T>(IDBRequest request, T Function(JSAny?) extract) {
    final completer = Completer<T>();
    request.onsuccess = ((Event _) {
      if (!completer.isCompleted) {
        completer.complete(extract(request.result));
      }
    }).toJS;
    request.onerror = ((Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          request.error ?? StateError('Запрос IndexedDB не удался'),
        );
      }
    }).toJS;
    return completer.future;
  }
}
