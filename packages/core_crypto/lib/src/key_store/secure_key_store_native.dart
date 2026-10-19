import 'package:core_domain/core_domain.dart';

/// Stub SecureKeyStore для нативных платформ (Android, Linux).
///
/// Реальная реализация с flutter_secure_storage находится в platform_android /
/// platform_linux. Этот stub выбрасывает UnimplementedError, пока реальная
/// реализация не подключена через DI.
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
