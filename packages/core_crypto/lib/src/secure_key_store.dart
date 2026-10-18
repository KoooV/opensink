import 'package:core_domain/core_domain.dart';
import 'identity.dart';

/// Интерфейс над платформенным хранилищем секретов (Keystore / libsecret / Web Crypto).
///
/// Реализация предоставляется platform_* пакетами через conditional import.
/// В core_crypto — только контракт и in-memory fake.
abstract class SecureKeyStore {
  /// Сохраняет зашифрованную идентичность.
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle);

  /// Загружает зашифрованную идентичность.
  Future<IdentityBundle?> loadIdentity(UserId userId);

  /// Удаляет идентичность.
  Future<void> deleteIdentity(UserId userId);

  /// Проверяет наличие идентичности.
  Future<bool> hasIdentity(UserId userId);
}

/// In-memory fake SecureKeyStore для тестов.
class FakeSecureKeyStore implements SecureKeyStore {
  final _store = <UserId, IdentityBundle>{};

  @override
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle) async {
    _store[userId] = bundle;
  }

  @override
  Future<IdentityBundle?> loadIdentity(UserId userId) => Future.value(_store[userId]);

  @override
  Future<void> deleteIdentity(UserId userId) async {
    _store.remove(userId);
  }

  @override
  Future<bool> hasIdentity(UserId userId) => Future.value(_store.containsKey(userId));
}
