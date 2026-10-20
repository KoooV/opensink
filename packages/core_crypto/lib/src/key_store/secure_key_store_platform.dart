import 'package:core_domain/core_domain.dart';

/// Заглушка SecureKeyStore, выбрасывающая/domain-ошибку при любом вызове.
///
/// Реальная платформенная реализация находится в `platform_android` /
/// `platform_linux` / `platform_web` и подключается через DI. Эта заглушка
/// не подключается по умолчанию.
class SecureKeyStoreStub implements SecureKeyStore {
  SecureKeyStoreStub();

  static const _notImplemented = StoreError(
    'SecureKeyStore не реализован в core_crypto. '
    'Используйте платформенную реализацию из platform_android / '
    'platform_linux / platform_web.',
  );

  @override
  Future<Result<void, KeyStoreError>> storeIdentity(
    UserId userId,
    IdentityBundle bundle,
  ) async =>
      const Err(_notImplemented);

  @override
  Future<Result<IdentityBundle, KeyStoreError>> loadIdentity(UserId userId) async =>
      const Err(_notImplemented);

  @override
  Future<Result<void, KeyStoreError>> deleteIdentity(UserId userId) async =>
      const Err(_notImplemented);

  @override
  Future<Result<bool, KeyStoreError>> hasIdentity(UserId userId) async =>
      const Err(_notImplemented);
}
