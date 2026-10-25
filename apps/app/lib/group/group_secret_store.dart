import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';

/// Хранит `GroupSecret` в платформенном [SecureKeyStore].
///
/// Отсутствие ключа — не ошибка: `load` возвращает `Ok(null)`. Секрет не
/// попадает в тексты ошибок.
class SecureGroupSecretStore implements GroupSecretStore {
  const SecureGroupSecretStore(this._store);

  static const String _prefix = 'opensink.group_secret.v1:';

  final SecureKeyStore _store;

  String _keyId(GroupId groupId) => '$_prefix${groupId.value}';

  @override
  Future<Result<void, GroupSecretError>> save(
    GroupId groupId,
    List<int> secret,
  ) async {
    if (secret.length != 32) {
      return const Err(CorruptedGroupSecret('secret is not 32 bytes'));
    }
    final stored = await _store.storeKey(_keyId(groupId), secret);
    if (stored.isErr) {
      return Err(GroupSecretStorageFailure(stored.unwrapErr().toString()));
    }
    return const Ok(null);
  }

  @override
  Future<Result<List<int>?, GroupSecretError>> load(GroupId groupId) async {
    final loaded = await _store.loadKey(_keyId(groupId));
    if (loaded.isErr) {
      if (loaded.unwrapErr() is IdentityNotFound) return const Ok(null);
      return Err(GroupSecretStorageFailure(loaded.unwrapErr().toString()));
    }
    final secret = loaded.unwrap();
    if (secret.length != 32) {
      return const Err(CorruptedGroupSecret('stored secret is not 32 bytes'));
    }
    return Ok(List<int>.unmodifiable(secret));
  }

  @override
  Future<Result<void, GroupSecretError>> delete(GroupId groupId) async {
    final deleted = await _store.deleteKey(_keyId(groupId));
    if (deleted.isErr) {
      if (deleted.unwrapErr() is IdentityNotFound) return const Ok(null);
      return Err(GroupSecretStorageFailure(deleted.unwrapErr().toString()));
    }
    return const Ok(null);
  }
}
