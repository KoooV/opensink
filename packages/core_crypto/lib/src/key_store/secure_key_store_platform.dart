import 'package:core_domain/core_domain.dart';

/// Stub SecureKeyStore для нативных платформ (Android, Linux).
class NativeSecureKeyStore implements SecureKeyStore {
  NativeSecureKeyStore();

  @override
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle) async {
    throw UnimplementedError(
      'NativeSecureKeyStore не реализован в core_crypto. '
      'Используйте платформенную реализацию из platform_android / platform_linux.',
    );
  }

  @override
  Future<IdentityBundle?> loadIdentity(UserId userId) async {
    throw UnimplementedError('NativeSecureKeyStore не реализован в core_crypto.');
  }

  @override
  Future<void> deleteIdentity(UserId userId) async {
    throw UnimplementedError('NativeSecureKeyStore не реализован в core_crypto.');
  }

  @override
  Future<bool> hasIdentity(UserId userId) async {
    throw UnimplementedError('NativeSecureKeyStore не реализован в core_crypto.');
  }
}

/// Stub SecureKeyStore для Web.
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
