import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

/// Персист E2E-сессий в [SecureKeyStore] через [StateVault].
///
/// Записи изолированы [scope] (обычно `UserId`): после смены локальной
/// identity старые сессии не восстанавливаются. Ключ хранилища StateVault
/// создаётся лениво при первом сохранении.
class SecureE2eSessionStore implements E2eSessionStore {
  SecureE2eSessionStore(SecureKeyStore store, {required this.scope})
    : _store = store,
      _vault = StateVault(store);

  static const String _prefix = 'opensink.e2e_session.v1';

  final SecureKeyStore _store;
  final StateVault _vault;
  final String scope;

  String _keyId(String peerId) => '$_prefix:$scope:$peerId';

  StateVaultContext _context(String peerId) => StateVaultContext(
    kind: StateKind.doubleRatchet,
    stateId: '$scope:$peerId',
  );

  @override
  Future<Result<Uint8List?, E2eSessionStoreError>> load(String peerId) async {
    final stored = await _store.loadKey(_keyId(peerId));
    if (stored.isErr) {
      if (stored.unwrapErr() is IdentityNotFound) return const Ok(null);
      return const Err(E2eSessionStoreUnavailable());
    }

    final opened = await _vault.open(
      SealedState.fromBytes(Uint8List.fromList(stored.unwrap())),
      _context(peerId),
    );
    if (opened.isErr) return const Err(E2eSessionStoreCorrupted());
    return Ok(opened.unwrap());
  }

  @override
  Future<Result<void, E2eSessionStoreError>> save(
    String peerId,
    Uint8List state,
  ) async {
    final sealed = await _vault.seal(state, _context(peerId));
    if (sealed.isErr) return const Err(E2eSessionStoreUnavailable());

    final stored = await _store.storeKey(_keyId(peerId), sealed.unwrap().bytes);
    if (stored.isErr) return const Err(E2eSessionStoreUnavailable());
    return const Ok(null);
  }

  @override
  Future<Result<void, E2eSessionStoreError>> delete(String peerId) async {
    final deleted = await _store.deleteKey(_keyId(peerId));
    if (deleted.isErr && deleted.unwrapErr() is! IdentityNotFound) {
      return const Err(E2eSessionStoreUnavailable());
    }
    return const Ok(null);
  }
}
