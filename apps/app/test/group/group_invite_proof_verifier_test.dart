import 'package:app/group/group_invite_proof_verifier.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const groupId = GroupId('group-1');
  const inviteId = 'inv-1';
  const userId = UserId('carol');

  test('валидный proof проходит, чужой и битый отклоняются', () async {
    final secret = await GroupSecret.random();
    final verifier = await GroupInviteProofVerifier.create(secret);

    final proof = verifier.computeProof(
      groupId: groupId,
      inviteId: inviteId,
      userId: userId,
    );

    expect(
      verifier.verify(
        groupId: groupId,
        inviteId: inviteId,
        userId: userId,
        proof: proof,
      ),
      isTrue,
    );
    expect(
      verifier.verify(
        groupId: groupId,
        inviteId: 'inv-2',
        userId: userId,
        proof: proof,
      ),
      isFalse,
    );
    expect(
      verifier.verify(
        groupId: groupId,
        inviteId: inviteId,
        userId: userId,
        proof: proof.replaceRange(0, 2, '00'),
      ),
      isFalse,
    );
    expect(
      verifier.verify(
        groupId: groupId,
        inviteId: inviteId,
        userId: userId,
        proof: 'zz',
      ),
      isFalse,
    );
  });

  test('другой group_secret не принимается', () async {
    final first = await GroupInviteProofVerifier.create(
      await GroupSecret.random(),
    );
    final second = await GroupInviteProofVerifier.create(
      await GroupSecret.random(),
    );

    final proof = first.computeProof(
      groupId: groupId,
      inviteId: inviteId,
      userId: userId,
    );

    expect(
      second.verify(
        groupId: groupId,
        inviteId: inviteId,
        userId: userId,
        proof: proof,
      ),
      isFalse,
    );
  });

  test('toString не раскрывает ключ', () async {
    final verifier = await GroupInviteProofVerifier.create(
      await GroupSecret.random(),
    );

    expect(verifier.toString(), 'GroupInviteProofVerifier(<secret>)');
  });
}
