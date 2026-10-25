import 'dart:convert';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// Production-проверка доказательства инвайта для `MemberJoined`.
///
/// HMAC-SHA256 над [inviteProofMessage] ключом `invitationKey`, выведенным из
/// `GroupSecret`. Синхронная проверка, потому что `GroupState.apply` чистая.
class GroupInviteProofVerifier implements InviteProofVerifier {
  GroupInviteProofVerifier._(this._key);

  static Future<GroupInviteProofVerifier> create(GroupSecret secret) async {
    final invitationKey = await secret.invitationKey();
    final bytes = await invitationKey.extractBytes();
    return GroupInviteProofVerifier._(SecretKeyData(bytes));
  }

  final SecretKeyData _key;
  final _hmac = DartHmac.sha256();

  String computeProof({
    required GroupId groupId,
    required String inviteId,
    required UserId userId,
  }) {
    final mac = _hmac.calculateMacSync(
      utf8.encode(
        inviteProofMessage(
          groupId: groupId,
          inviteId: inviteId,
          userId: userId,
        ),
      ),
      secretKeyData: _key,
      nonce: const [],
    );
    return bytesToHex(mac.bytes);
  }

  @override
  bool verify({
    required GroupId groupId,
    required String inviteId,
    required UserId userId,
    required String proof,
  }) {
    final expected = _hmac.calculateMacSync(
      utf8.encode(
        inviteProofMessage(
          groupId: groupId,
          inviteId: inviteId,
          userId: userId,
        ),
      ),
      secretKeyData: _key,
      nonce: const [],
    );
    final actual = _decodeHex(proof);
    if (actual == null || actual.length != expected.bytes.length) {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < actual.length; i++) {
      difference |= actual[i] ^ expected.bytes[i];
    }
    return difference == 0;
  }

  @override
  String toString() => 'GroupInviteProofVerifier(<secret>)';

  static Uint8List? _decodeHex(String value) {
    if (value.isEmpty || value.length.isOdd) return null;
    final result = Uint8List(value.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      final byte = int.tryParse(value.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      result[i] = byte;
    }
    return result;
  }
}

/// Кэш проверяющих по группам поверх [GroupSecretStore].
///
/// `InviteProofVerifier` синхронный, поэтому секрет загружается заранее:
/// перед созданием/входом в группу или перед открытием моста.
class GroupInviteProofVerifierRegistry implements InviteProofVerifier {
  GroupInviteProofVerifierRegistry(this._store);

  final GroupSecretStore _store;
  final Map<String, GroupInviteProofVerifier> _verifiers =
      <String, GroupInviteProofVerifier>{};

  Future<void> preload(GroupId groupId) async {
    final loaded = await _store.load(groupId);
    if (loaded.isErr) return;
    final secret = loaded.unwrap();
    if (secret == null) return;
    await rememberBytes(groupId, secret);
  }

  Future<void> rememberBytes(GroupId groupId, List<int> secret) async {
    if (secret.length != 32) {
      _verifiers.remove(groupId.value);
      return;
    }
    final verifier = await GroupInviteProofVerifier.create(
      GroupSecret(SecretKeyData(Uint8List.fromList(secret))),
    );
    _verifiers[groupId.value] = verifier;
  }

  void forget(GroupId groupId) {
    _verifiers.remove(groupId.value);
  }

  @override
  bool verify({
    required GroupId groupId,
    required String inviteId,
    required UserId userId,
    required String proof,
  }) {
    final verifier = _verifiers[groupId.value];
    if (verifier == null) return false;
    return verifier.verify(
      groupId: groupId,
      inviteId: inviteId,
      userId: userId,
      proof: proof,
    );
  }

  @override
  String toString() => 'GroupInviteProofVerifierRegistry(<secret>)';
}
