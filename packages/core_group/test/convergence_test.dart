import 'dart:math';

import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  test('любой порядок доставки даёт идентичный GroupState', () {
    final events = <GroupEvent>[
      created(),
      inviteIssued(
        id: 'invite-open',
        inviteId: 'inv-open',
        maxUses: 10,
        expiresAt: 10000,
      ),
      joined(id: 'join-carol', inviteId: 'inv-open', userId: carol),
      roleSet(
        id: 'role-alice',
        userId: alice,
        role: GroupRole.admin,
        timestamp: 12,
      ),
      roleSet(
        id: 'role-bob',
        userId: bob,
        role: GroupRole.moderator,
        timestamp: 13,
      ),
      channelCreated(
        id: 'channel-general',
        channelId: 'general',
        minPostRole: GroupRole.moderator,
      ),
      renamed(id: 'rename-main', timestamp: 17),
      keyRotated(id: 'rotate-manual', newEpoch: 2, timestamp: 18),
      removed(id: 'kick-bob', authorId: alice, userId: bob, timestamp: 40),
      added(id: 'add-dave', authorId: alice, userId: dave, timestamp: 45),
      inviteIssued(
        id: 'forbidden-invite',
        inviteId: 'inv-bad',
        authorId: carol,
        timestamp: 50,
      ),
      channelDeleted(id: 'channel-delete', authorId: alice, timestamp: 55),
      const OwnerTransferred(
        id: EventId('transfer-owner'),
        groupId: testGroupId,
        authorId: owner,
        timestamp: 80,
        newOwnerId: alice,
      ),
      removed(
        id: 'kick-old-owner',
        authorId: alice,
        userId: owner,
        timestamp: 90,
      ),
    ];

    final reference = buildState(events, inviteProofVerifier: allowAllProofs);
    final random = Random(20261024);

    for (var run = 0; run < 300; run++) {
      final shuffled = List<GroupEvent>.of(events)..shuffle(random);
      expect(
        buildState(shuffled, inviteProofVerifier: allowAllProofs),
        reference,
        reason: 'run $run, order ${shuffled.map((e) => e.id.value).toList()}',
      );
    }
  });

  test('дубликаты событий не меняют состояние', () {
    final events = <GroupEvent>[
      created(),
      roleSet(id: 'role-alice', userId: alice, role: GroupRole.admin),
      removed(id: 'kick-bob', authorId: alice, userId: bob),
    ];

    final once = buildState(events);
    final twice = buildState([...events, ...events]);

    expect(twice, once);
  });
}
