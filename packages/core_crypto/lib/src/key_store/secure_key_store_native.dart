/// Платформенная реализация SecureKeyStore (native: Android, Linux).
///
/// Реализацияflutter_secure_storage находится в platform_android /
/// platform_linux. Этот файл в core_crypto — заглушка, которая выбрасывает
/// UnimplementedError, пока реальная реализация не подключена через DI.
class NativeSecureKeyStore implements SecureKeyStore {
  NativeSecureKeyStore();

  @override
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle) async {
    throw UnimplementedError('NativeSecureKeyStore не реализован в core_crypto. '
        'Используйте платформенную реализацию из platform_android / platform_linux.');
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
