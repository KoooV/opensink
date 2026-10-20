import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_domain/core_domain.dart';

/// Общий контракт SecureKeyStore для любой реализации.
///
/// Прогоняется для `MemorySecureKeyStore` (VM) и для
/// `WebSecureKeyStoreImpl` (Chrome).
///
/// Покрывает: запись/чтение, перезапись, удаление, отсутствующий ключ,
/// пустое значение, большое значение.
void secureKeyStoreContract(SecureKeyStore Function() factory, {String label = ''}) {
  group('SecureKeyStore контракт$label', () {
    late SecureKeyStore store;

    const userId = UserId('user-contract');

    IdentityBundle bundle({
      String publicKey = 'pk-hex',
      List<int>? privateKey,
      int createdAt = 1000,
    }) =>
        IdentityBundle(
          userId: userId,
          publicKey: publicKey,
          encryptedPrivateKey: privateKey ?? [1, 2, 3],
          createdAt: createdAt,
        );

    setUp(() {
      store = factory();
    });

    T okValue<T, E>(Result<T, E> result) {
      expect(result.isOk, isTrue, reason: 'expected Ok, got $result');
      return (result as Ok<T, E>).value;
    }

    E errValue<T, E>(Result<T, E> result) {
      expect(result.isErr, isTrue, reason: 'expected Err, got $result');
      return (result as Err<T, E>).error;
    }

    test('отсутствующий ключ: hasIdentity false, loadIdentity IdentityNotFound', () async {
      expect(okValue(await store.hasIdentity(userId)), isFalse);
      final err = errValue(await store.loadIdentity(userId));
      expect(err, isA<IdentityNotFound>());
    });

    test('запись и чтение IdentityBundle', () async {
      final stored = await store.storeIdentity(userId, bundle());
      expect(stored.isOk, isTrue);
      expect(okValue(await store.hasIdentity(userId)), isTrue);
      expect(okValue(await store.loadIdentity(userId)), equals(bundle()));
    });

    test('перезапись заменяет предыдущее значение', () async {
      await store.storeIdentity(userId, bundle(publicKey: 'pk-1', privateKey: [9]));
      await store.storeIdentity(userId, bundle(publicKey: 'pk-2', privateKey: [8]));
      expect(
        okValue(await store.loadIdentity(userId)),
        equals(bundle(publicKey: 'pk-2', privateKey: [8])),
      );
    });

    test('удаление удаляет запись', () async {
      await store.storeIdentity(userId, bundle());
      expect(okValue(await store.hasIdentity(userId)), isTrue);
      final deleted = await store.deleteIdentity(userId);
      expect(deleted.isOk, isTrue);
      expect(okValue(await store.hasIdentity(userId)), isFalse);
      final err = errValue(await store.loadIdentity(userId));
      expect(err, isA<IdentityNotFound>());
    });

    test('пустое encryptedPrivateKey допустимо', () async {
      final empty = bundle(privateKey: []);
      await store.storeIdentity(userId, empty);
      final loaded = okValue(await store.loadIdentity(userId));
      expect(loaded, equals(empty));
      expect(loaded.encryptedPrivateKey, isEmpty);
    });

    test('большое значение хранится и читается корректно', () async {
      final large = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 42);
      final big = bundle(privateKey: large);
      await store.storeIdentity(userId, big);
      expect(okValue(await store.loadIdentity(userId)), equals(big));
    });
  });
}
