import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:test/test.dart';

/// Проверяет, что `MemorySecureKeyStore` (in-memory fake) может использоваться
/// для тестирования через Riverpod provider overrides.
///
/// Продакшен-реализация подключается через `createPlatformSecureKeyStore()`
/// (conditional import: `platform_android` для Android/Linux, `platform_web`
/// для Web). Прямой вызов платформенного хранилища в `dart test` невозможен,
/// т.к. `platform_android` / `platform_linux` зависят от Flutter SDK и
/// требуют `flutter test`. Полное интеграционное тестирование платформенных
/// хранилищ выполняется в `platform_*` пакетах через `flutter test`.
void main() {
  group('DI: SecureKeyStore тестирование через override', () {
    test('MemorySecureKeyStore реализует SecureKeyStore contrato', () async {
      final store = MemorySecureKeyStore();
      const userId = UserId('di-test-user');

      // Отсутствует изначально.
      final hasBefore = await store.hasIdentity(userId);
      expect(hasBefore.isOk, isTrue);
      expect((hasBefore as Ok<bool, KeyStoreError>).value, isFalse);

      // Запись и чтение.
      final stored = await store.storeIdentity(
        userId,
        const IdentityBundle(
          userId: UserId('di-test-user'),
          publicKey: 'pk-hex',
          privateSeed: [1, 2, 3],
          createdAt: 1000,
        ),
      );
      expect(stored.isOk, isTrue);

      final loaded = await store.loadIdentity(userId);
      expect(loaded.isOk, isTrue);
      final bundle = (loaded as Ok<IdentityBundle, KeyStoreError>).value;
      expect(bundle.publicKey, equals('pk-hex'));
      expect(bundle.privateSeed, equals([1, 2, 3]));

      // Удаление.
      final deleted = await store.deleteIdentity(userId);
      expect(deleted.isOk, isTrue);
      final loadedAgain = await store.loadIdentity(userId);
      expect(loadedAgain.unwrapErr(), isA<IdentityNotFound>());
    });

    test('storeKey / loadKey / deleteKey roundtrip', () async {
      final store = MemorySecureKeyStore();
      const keyId = 'opensink_state_vault_v1';
      const bytes = [0xde, 0xad, 0xbe, 0xef];

      final stored = await store.storeKey(keyId, bytes);
      expect(stored.isOk, isTrue);

      final loaded = await store.loadKey(keyId);
      expect(loaded.isOk, isTrue);
      expect((loaded as Ok<List<int>, KeyStoreError>).value, equals(bytes));

      final deleted = await store.deleteKey(keyId);
      expect(deleted.isOk, isTrue);
    });
  });
}
