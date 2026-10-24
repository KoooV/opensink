import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

GroupState stateOf(
  Iterable<GroupEvent> events, {
  GroupId expectedGroupId = testGroupId,
  EventId genesisEventId = const EventId('create'),
  InviteProofVerifier? inviteProofVerifier,
}) {
  return GroupState.fromEvents(
    events,
    expectedGroupId: expectedGroupId,
    genesisEventId: genesisEventId,
    inviteProofVerifier: inviteProofVerifier,
  );
}

void main() {
  final proofVerifier = InMemoryInviteProofVerifier()
    ..allow(
      groupId: testGroupId,
      inviteId: 'inv-1',
      userId: carol,
      proof: 'valid-carol',
    );

  group('prevId и монотонность HLC автора', () {
    test('событие с HLC не больше prev не применяется', () {
      final first = roleSet(
        id: 'role-first',
        userId: alice,
        role: GroupRole.admin,
        timestamp: 10,
        prevId: const EventId('create'),
      );
      final backdated = renamed(
        id: 'backdated',
        name: 'Backdated',
        timestamp: 5,
        prevId: const EventId('role-first'),
      );

      final state = stateOf([created(), first, backdated]);

      expect(state.members[alice], GroupRole.admin);
      expect(state.name, 'Test group');
      expect(
        state.appliedEventIds.contains(const EventId('backdated')),
        isTrue,
      );
    });

    test('prevId на событие другого автора отклоняется', () {
      final ownerRole = roleSet(
        id: 'role-owner',
        userId: bob,
        role: GroupRole.admin,
        timestamp: 9,
      );
      final aliceRole = roleSet(
        id: 'role-alice',
        userId: alice,
        role: GroupRole.admin,
        authorId: alice,
        timestamp: 10,
      );
      final forged = renamed(
        id: 'forged',
        name: 'Forged',
        authorId: alice,
        timestamp: 11,
        prevId: const EventId('role-owner'),
      );

      final state = stateOf([created(), ownerRole, aliceRole, forged]);

      expect(state.name, isNot('Forged'));
    });

    test('форк одного prevId сходится к детерминированному ребёнку', () {
      final root = roleSet(
        id: 'root',
        userId: alice,
        role: GroupRole.admin,
        timestamp: 10,
        prevId: const EventId('create'),
      );
      final alpha = renamed(
        id: 'alpha',
        name: 'Alpha',
        timestamp: 20,
        prevId: const EventId('root'),
      );
      final beta = renamed(
        id: 'beta',
        name: 'Beta',
        timestamp: 21,
        prevId: const EventId('root'),
      );

      final first = stateOf([created(), root, alpha, beta]);
      final second = stateOf([created(), beta, root, alpha]);

      expect(first, second);
      expect(first.name, 'Alpha');
    });
  });

  group('корень истории группы', () {
    test('expectedGroupId отсекает чужое создание', () {
      final evil = created(
        id: 'evil',
        groupId: const GroupId('evil'),
        timestamp: 0,
      );
      final real = created(id: 'real', timestamp: 1);

      final state = stateOf(
        [evil, real],
        expectedGroupId: testGroupId,
        genesisEventId: const EventId('real'),
      );

      expect(state.id, testGroupId);
      expect(state.createdAt, 1);
    });

    test('genesisEventId фиксирует конкретное создание', () {
      final fake = created(id: 'fake', timestamp: 0);
      final real = created(id: 'real', timestamp: 1);

      final state = stateOf(
        [fake, real],
        expectedGroupId: testGroupId,
        genesisEventId: const EventId('real'),
      );

      expect(state.createdAt, 1);
    });
  });

  group('дедупликация по id', () {
    test('одинаковый id с разными телами выбирается детерминированно', () {
      final alpha = renamed(
        id: 'dup',
        name: 'Alpha',
        timestamp: 20,
        prevId: const EventId('create'),
      );
      final beta = renamed(
        id: 'dup',
        name: 'Beta',
        timestamp: 20,
        prevId: const EventId('create'),
      );

      final first = stateOf([created(), alpha, beta]);
      final second = stateOf([created(), beta, alpha]);

      expect(first, second);
      expect(first.name, 'Alpha');
    });

    test('дедуп не скрывает чужой groupId', () {
      final state = stateOf([created()]);
      final foreign = GroupCreated(
        id: const EventId('create'),
        groupId: const GroupId('other'),
        authorId: owner,
        timestamp: 0,
        name: 'Evil',
        ownerId: owner,
        initialMembers: {owner},
      );

      final result = state.apply(foreign);

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<GroupIdMismatch>());
    });

    test('отклонённые и no-op события помечаются applied', () {
      final state = stateOf([
        created(),
        inviteIssued(id: 'forbidden-invite', authorId: carol),
        added(id: 'noop-add', userId: bob),
      ]);

      expect(
        state.appliedEventIds.contains(const EventId('forbidden-invite')),
        isTrue,
      );
      expect(state.appliedEventIds.contains(const EventId('noop-add')), isTrue);
    });
  });

  group('доказательство владения инвайтом', () {
    test('валидный proof добавляет участника', () {
      final state = stateOf([
        created(initialMembers: {owner, alice}),
        inviteIssued(maxUses: 2),
        joined(userId: carol, inviteProof: 'valid-carol'),
      ], inviteProofVerifier: proofVerifier);

      expect(state.members[carol], GroupRole.member);
      expect(state.invites['inv-1']?.uses, 1);
    });

    test('вход только по публичному inviteId отклоняется', () {
      final result = stateOf(
        [
          created(initialMembers: {owner, alice}),
          inviteIssued(),
        ],
        inviteProofVerifier: proofVerifier,
      ).apply(joined(userId: carol, inviteProof: ''));

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InviteProofRequired>());
    });

    test('proof от другого инвайта отклоняется', () {
      final state = stateOf([
        created(initialMembers: {owner, alice}),
        inviteIssued(id: 'invite-one', inviteId: 'inv-1', maxUses: 5),
        inviteIssued(
          id: 'invite-two',
          inviteId: 'inv-2',
          maxUses: 5,
          timestamp: 11,
        ),
        joined(userId: carol, inviteId: 'inv-2', inviteProof: 'valid-carol'),
      ], inviteProofVerifier: proofVerifier);

      expect(state.members.containsKey(carol), isFalse);
    });

    test('бэкдейтинг входа до истечения срока отклоняется цепочкой', () {
      final late = joined(
        id: 'late-join',
        userId: carol,
        inviteProof: 'valid-carol',
        timestamp: 200,
      );
      final backdated = joined(
        id: 'backdated-join',
        userId: carol,
        inviteProof: 'valid-carol',
        timestamp: 50,
        prevId: const EventId('late-join'),
      );

      final state = stateOf([
        created(initialMembers: {owner, alice}),
        inviteIssued(maxUses: 5, expiresAt: 100),
        late,
        backdated,
      ], inviteProofVerifier: proofVerifier);

      expect(state.members.containsKey(carol), isFalse);
    });

    test('просроченный инвайт отклоняется даже с валидным proof', () {
      final state = stateOf([
        created(initialMembers: {owner, alice}),
        inviteIssued(maxUses: 5, expiresAt: 100),
        joined(userId: carol, inviteProof: 'valid-carol', timestamp: 101),
      ], inviteProofVerifier: proofVerifier);

      expect(state.members.containsKey(carol), isFalse);
    });
  });
}
