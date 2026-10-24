import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('открытый инвайт', () {
    test('вход по ссылке добавляет участника', () {
      final state = buildState([
        created(initialMembers: {owner, alice}),
        inviteIssued(maxUses: 2, expiresAt: 1000),
        joined(userId: carol),
      ], inviteProofVerifier: allowAllProofs);

      expect(state.members[carol], GroupRole.member);
      expect(state.invites['inv-1']?.uses, 1);
    });

    test('исчерпанный инвайт отклоняется', () {
      final state = buildState([
        created(initialMembers: {owner, alice}),
        inviteIssued(maxUses: 1),
        joined(id: 'join-carol', userId: carol),
        joined(id: 'join-dave', userId: dave, timestamp: 21),
      ], inviteProofVerifier: allowAllProofs);

      expect(state.members.containsKey(carol), isTrue);
      expect(state.members.containsKey(dave), isFalse);
    });

    test('просроченный инвайт отклоняется', () {
      final state = buildState([
        created(initialMembers: {owner, alice}),
        inviteIssued(maxUses: 5, expiresAt: 100),
        joined(userId: carol, timestamp: 101),
      ], inviteProofVerifier: allowAllProofs);

      expect(state.members.containsKey(carol), isFalse);
    });

    test('неизвестный inviteId отклоняется', () {
      final state = buildState([
        created(initialMembers: {owner, alice}),
        inviteIssued(),
        joined(inviteId: 'unknown', userId: carol),
      ], inviteProofVerifier: allowAllProofs);

      expect(state.members.containsKey(carol), isFalse);
    });
  });

  group('инвайт с подтверждением', () {
    test('вход создаёт заявку, админ подтверждает', () {
      final setup = <GroupEvent>[
        created(initialMembers: {owner, alice}),
        roleSet(id: 'role-alice', userId: alice, role: GroupRole.admin),
        inviteIssued(mode: InviteMode.approval, maxUses: 1),
        joined(userId: carol),
      ];
      final pending = buildState(setup, inviteProofVerifier: allowAllProofs);

      expect(pending.members.containsKey(carol), isFalse);
      expect(pending.pendingJoins[carol], 'inv-1');
      expect(pending.invites['inv-1']?.uses, 0);

      final confirmed = pending
          .apply(approved(userId: carol, authorId: alice, timestamp: 30))
          .unwrap();

      expect(confirmed.members[carol], GroupRole.member);
      expect(confirmed.pendingJoins.containsKey(carol), isFalse);
      expect(confirmed.invites['inv-1']?.uses, 1);
    });

    test('подтверждение не-админом отклоняется', () {
      final setup = <GroupEvent>[
        created(initialMembers: {owner, alice}),
        inviteIssued(mode: InviteMode.approval, maxUses: 1),
        joined(userId: carol),
      ];
      final result = buildState(setup, inviteProofVerifier: allowAllProofs)
          .apply(
            approved(
              userId: carol,
              authorId: carol,
              timestamp: 30,
              prevId: const EventId('join-1'),
            ),
          );

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<Forbidden>());
    });

    test('подтверждение без заявки отклоняется', () {
      final setup = <GroupEvent>[
        created(initialMembers: {owner, alice}),
        inviteIssued(mode: InviteMode.approval, maxUses: 1),
      ];
      final result = buildState(setup, inviteProofVerifier: allowAllProofs)
          .apply(
            approved(
              userId: carol,
              timestamp: 30,
              prevId: const EventId('invite-1'),
            ),
          );

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<JoinNotPending>());
    });
  });

  test('не-админ не может выдать инвайт', () {
    final setup = <GroupEvent>[
      created(initialMembers: {owner, alice}),
      added(id: 'add-carol', userId: carol),
    ];
    final result = buildState(
      setup,
    ).apply(inviteIssued(id: 'invite-carol', authorId: carol, timestamp: 20));

    expect(result.isErr, isTrue);
    expect(result.unwrapErr(), isA<Forbidden>());
  });

  test('InviteLink не раскрывает секрет в toString и восстанавливается', () {
    const link = InviteLink(
      groupId: testGroupId,
      inviteId: 'inv-1',
      secret: 'secret-token',
      inviterId: owner,
      relayHint: 'wss://relay.example',
    );

    final encoded = link.toUriString();
    final decoded = InviteLink.parse(encoded);

    expect(decoded.isOk, isTrue);
    final parsed = decoded.unwrap();
    expect(parsed.groupId, testGroupId);
    expect(parsed.inviteId, 'inv-1');
    expect(parsed.secret, 'secret-token');
    expect(parsed.inviterId, owner);
    expect(parsed.relayHint, 'wss://relay.example');
    expect(link.toString(), isNot(contains('secret-token')));
  });
}
