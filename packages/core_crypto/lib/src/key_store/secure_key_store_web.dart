/// Платформенная реализация SecureKeyStore (Web).
///
/// Реализация на Web Crypto API + IndexedDB находится в platform_web.
/// Этот файл в core_crypto — заглушка.
class WebSecureKeyStoreStub implements SecureKeyStore {
  WebSecureKeyStoreStub();

  @override
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle) async {
    throw UnimplementedError('WebSecureKeyStore не реализован в core_crypto. '
        'Используйте платформенную реализацию из platform_web.');
  }

  @override
  Future<IdentityBundle?> loadIdentity(UserId userId) async {
    throw UnimplementedError('WebSecureKeyStore не реализован в core_crypto.');
  }

  @override
  Future<void> deleteIdentity(UserId userId) async {
    throw UnimplementedError('WebSecureKeyStore не реализован в core_crypto.');
  }

  @override
  Future<bool> hasIdentity(UserId userId) async {
    throw UnimplementedError('WebSecureKeyStore не реализован в core_crypto.');
  }
}
