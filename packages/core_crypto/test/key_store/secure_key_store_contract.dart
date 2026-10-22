import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_domain/core_domain.dart';

/// Общий контракт SecureKeyStore для любой реализации.
///
/// Прогоняется для `MemorySecureKeyStore` (VM) и для платформенных
/// реализаций с замоканным плагином. Не зависит от платформы.
///
/// Покрывает: запись/чтение, перезапись, удаление, отсутствующий ключ,
/// пустое значение, большое значение (1 МБ), неверное имя ключа.
void runSecureKeyStoreContract(SecureKeyStore Function() factory,
    {String label = ''}) {
  group('SecureKeyStore контракт$label', () {
    late SecureKeyStore store;

    const userId = UserId('user-contract');

    IdentityBundle bundle({
      String publicKey = 'pk-hex',
      List<int>? privateSeed,
      int createdAt = 1000,
    }) =>
        IdentityBundle(
          userId: userId,
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

    setUp(() {
      store = factory();
    });

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
      await store.storeIdentity(userId, bundle(publicKey: 'pk-1', privateSeed: [9]));
      await store.storeIdentity(userId, bundle(publicKey: 'pk-2', privateSeed: [8]));
      expect(
        okValue(await store.loadIdentity(userId)),
        equals(bundle(publicKey: 'pk-2', privateSeed: [8])),
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

    test('пустое privateSeed допустимо', () async {
      final empty = bundle(privateSeed: []);
      await store.storeIdentity(userId, empty);
      final loaded = okValue(await store.loadIdentity(userId));
      expect(loaded, equals(empty));
      expect(loaded.privateSeed, isEmpty);
    });

    test('большое значение (1 МБ) хранится и читается корректно', () async {
      final large = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 42);
      final big = bundle(privateSeed: large);
      await store.storeIdentity(userId, big);
      expect(okValue(await store.loadIdentity(userId)), equals(big));
    });

    test('неверное имя ключа (пустой userId) обрабатывается без исключения', () async {
      const emptyUserId = UserId('');
      final result = await store.storeIdentity(emptyUserId, bundle());
      // Хранилище должно обработать пустой ключ либо Ok, либо Err — без исключения.
      expect(result.isOk || result.isErr, isTrue);
      if (result.isErr) {
        final err = result.unwrapErr();
        expect(
          err,
          isA<KeyStoreError>(),
          reason: 'expected KeyStoreError subtype, got $err',
        );
      }
    });
  });
}
