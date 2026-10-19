import 'package:core_domain/core_domain.dart';

/// In-memory SecureKeyStore для тестов и разработки.
///
/// Не сохраняет данные между перезапусками. Секреты хранятся в открытом виде
/// в оперативной памяти — не использовать в продакшене.
class MemorySecureKeyStore implements SecureKeyStore {
  MemorySecureKeyStore();

  final _store = <String, IdentityBundle>{};

  @override
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle) async {
    _store[userId.value] = bundle;
  }

  @override
  Future<IdentityBundle?> loadIdentity(UserId userId) async =>
      _store[userId.value];

  @override
  Future<void> deleteIdentity(UserId userId) async {
    _store.remove(userId.value);
  }

  @override
  Future<bool> hasIdentity(UserId userId) async =>
      _store.containsKey(userId.value);
}
