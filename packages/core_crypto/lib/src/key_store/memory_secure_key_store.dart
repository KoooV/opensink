import 'package:core_domain/core_domain.dart';
import 'package:meta/meta.dart';

/// In-memory SecureKeyStore для тестов и разработки.
///
/// Не сохраняет данные между перезапусками. Секреты хранятся в открытом виде
/// в оперативной памяти — **не использовать в продакшене**.
@visibleForTesting
class MemorySecureKeyStore implements SecureKeyStore {
  /// Создаёт in-memory хранилище.
  ///
  /// Помечено [visibleForTesting]: не для продакшена.
  MemorySecureKeyStore();

  final _store = <String, IdentityBundle>{};

  @override
  Future<Result<void, KeyStoreError>> storeIdentity(
    UserId userId,
    IdentityBundle bundle,
  ) async {
    _store[userId.value] = bundle;
    return const Ok(null);
  }

  @override
  Future<Result<IdentityBundle, KeyStoreError>> loadIdentity(
    UserId userId,
  ) async {
    final bundle = _store[userId.value];
    if (bundle == null) {
      return const Err(IdentityNotFound());
    }
    return Ok(bundle);
  }

  @override
  Future<Result<void, KeyStoreError>> deleteIdentity(UserId userId) async {
    _store.remove(userId.value);
    return const Ok(null);
  }

  @override
  Future<Result<bool, KeyStoreError>> hasIdentity(UserId userId) async =>
      Ok(_store.containsKey(userId.value));

  @override
  String toString() => 'MemorySecureKeyStore(${_store.length} записей)';
}
