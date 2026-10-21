import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:platform_web/platform_web.dart';
import 'package:core_domain/core_domain.dart';

int _webDbCounter = 0;

SecureKeyStore _webFactory() =>
    WebSecureKeyStoreImpl(dbName: 'opensink_ks_web_test_${_webDbCounter++}');

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

void main() {
  group('WebSecureKeyStoreImpl (Chrome, IndexedDB + Web Crypto API)', () {
    late SecureKeyStore store;

    const userId = UserId('user-web');

    setUp(() {
      store = _webFactory();
    });

    test('отсутствующий ключ: hasIdentity false, loadIdentity IdentityNotFound', () async {
      expect(okValue(await store.hasIdentity(userId)), isFalse);
      final err = errValue(await store.loadIdentity(userId));
      expect(err, isA<IdentityNotFound>());
    });

    test('запись и чтение IdentityBundle через IndexedDB + AES-GCM KEK', () async {
      final stored = await store.storeIdentity(userId, _bundle());
      expect(stored.isOk, isTrue);
      expect(okValue(await store.hasIdentity(userId)), isTrue);
      expect(okValue(await store.loadIdentity(userId)), equals(_bundle()));
    });

    test('перезапись заменяет предыдущее значение', () async {
      await store.storeIdentity(userId, _bundle(publicKey: 'pk-1', privateSeed: [9]));
      await store.storeIdentity(userId, _bundle(publicKey: 'pk-2', privateSeed: [8]));
      expect(
        okValue(await store.loadIdentity(userId)),
        equals(_bundle(publicKey: 'pk-2', privateSeed: [8])),
      );
    });

    test('удаление удаляет запись', () async {
      await store.storeIdentity(userId, _bundle());
      expect(okValue(await store.hasIdentity(userId)), isTrue);
      final deleted = await store.deleteIdentity(userId);
      expect(deleted.isOk, isTrue);
      expect(okValue(await store.hasIdentity(userId)), isFalse);
      final err = errValue(await store.loadIdentity(userId));
      expect(err, isA<IdentityNotFound>());
    });

    test('пустое privateSeed допустимо', () async {
      final empty = _bundle(privateSeed: []);
      await store.storeIdentity(userId, empty);
      final loaded = okValue(await store.loadIdentity(userId));
      expect(loaded, equals(empty));
      expect(loaded.privateSeed, isEmpty);
    });

    test('большое значение хранится и читается корректно', () async {
      final large = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 42);
      final big = _bundle(privateSeed: large);
      await store.storeIdentity(userId, big);
      expect(okValue(await store.loadIdentity(userId)), equals(big));
    });
  });
}
