import 'package:core_domain/core_domain.dart';

/// Stub SecureKeyStore для Web.
///
/// Реальная реализация на Web Crypto API + IndexedDB находится в platform_web.
/// Этот stub выбрасывает UnimplementedError, пока реальная реализация не
/// подключена через DI.
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
