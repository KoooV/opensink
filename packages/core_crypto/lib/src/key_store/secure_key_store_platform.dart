import 'package:core_domain/core_domain.dart';

/// Платформенная реализация SecureKeyStore (нативные: Android, Linux).
///
/// Реализация flutter_secure_storage находится в platform_android /
/// platform_linux. Этот файл в core_crypto — заглушка, которая выбрасывает
/// UnimplementedError, пока реальная реализация не подключена через DI.
class PlatformSecureKeyStore implements SecureKeyStore {
  PlatformSecureKeyStore();

  @override
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle) async {
    throw UnimplementedError(
      'PlatformSecureKeyStore не реализован в core_crypto. '
      'Используйте платформенную реализацию из platform_android / platform_linux.',
    );
  }

  @override
  Future<IdentityBundle?> loadIdentity(UserId userId) async {
    throw UnimplementedError(
      'PlatformSecureKeyStore не реализован в core_crypto.',
    );
  }

  @override
  Future<void> deleteIdentity(UserId userId) async {
    throw UnimplementedError(
      'PlatformSecureKeyStore не реализован в core_crypto.',
    );
  }

  @override
  Future<bool> hasIdentity(UserId userId) async {
    throw UnimplementedError(
      'PlatformSecureKeyStore не реализован в core_crypto.',
    );
  }
}

/// Платформенная реализация SecureKeyStore (Web).
///
/// Реализация на Web Crypto API + IndexedDB находится в platform_web.
/// Этот файл в core_crypto — заглушка.
class WebPlatformSecureKeyStore implements SecureKeyStore {
  WebPlatformSecureKeyStore();

  @override
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle) async {
    throw UnimplementedError(
      'WebPlatformSecureKeyStore не реализован в core_crypto. '
      'Используйте платформенную реализацию из platform_web.',
    );
  }

  @override
  Future<IdentityBundle?> loadIdentity(UserId userId) async {
    throw UnimplementedError('WebPlatformSecureKeyStore не реализован в core_crypto.');
  }

  @override
  Future<void> deleteIdentity(UserId userId) async {
    throw UnimplementedError('WebPlatformSecureKeyStore не реализован в core_crypto.');
  }

  @override
  Future<bool> hasIdentity(UserId userId) async {
    throw UnimplementedError('WebPlatformSecureKeyStore не реализован в core_crypto.');
  }
}
