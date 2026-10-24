import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('owner неприкосновенен', () {
    test('владельца нельзя удалить', () {
      final setup = <GroupEvent>[
        created(),
        roleSet(id: 'role-alice', userId: alice, role: GroupRole.admin),
      ];
      final state = buildState([
        ...setup,
        removed(id: 'kick-owner', authorId: alice, userId: owner),
      ]);

      expect(state.members[owner], GroupRole.owner);
      expect(state.members.containsKey(owner), isTrue);
    });

    test('владельца нельзя понизить', () {
      final state = buildState([
        created(),
        roleSet(id: 'demote-owner', userId: owner, role: GroupRole.admin),
      ]);

      expect(state.members[owner], GroupRole.owner);
    });
  });

  group('конкурентные действия равных ролей', () {
    test('взаимные кики: побеждает меньший (hlc, id)', () {
      final setup = <GroupEvent>[
        created(),
        roleSet(id: 'role-alice', userId: alice, role: GroupRole.admin),
        roleSet(id: 'role-bob', userId: bob, role: GroupRole.admin),
      ];
      final kickAlice = removed(
        id: 'kick-a',
        authorId: bob,
        userId: alice,
        timestamp: 20,
      );
      final kickBob = removed(
        id: 'kick-b',
        authorId: alice,
        userId: bob,
        timestamp: 20,
      );

      final first = buildState([...setup, kickAlice, kickBob]);
      final second = buildState([...setup, kickBob, kickAlice]);

      expect(first, second);
      expect(first.members.keys.toSet(), {owner, bob});
      expect(first.members.containsKey(alice), isFalse);
    });

    test('кик против смены роли сходится при любом порядке', () {
      final setup = <GroupEvent>[
        created(),
        roleSet(id: 'role-alice', userId: alice, role: GroupRole.admin),
      ];
      final promoteBob = roleSet(
        id: 'a-promote',
        userId: bob,
        role: GroupRole.admin,
        timestamp: 20,
      );
      final kickBob = removed(
        id: 'z-kick',
        authorId: alice,
        userId: bob,
        timestamp: 20,
      );

      final first = buildState([...setup, promoteBob, kickBob]);
      final second = buildState([...setup, kickBob, promoteBob]);

      expect(first, second);
      expect(first.members.containsKey(bob), isFalse);
    });

    test('кик раньше смены роли: смена роли удалённого отклоняется', () {
      final setup = <GroupEvent>[
        created(),
        roleSet(id: 'role-alice', userId: alice, role: GroupRole.admin),
      ];
      final kickBob = removed(
        id: 'a-kick',
        authorId: alice,
        userId: bob,
        timestamp: 20,
      );
      final promoteBob = roleSet(
        id: 'z-promote',
        userId: bob,
        role: GroupRole.moderator,
        timestamp: 20,
      );

      final state = buildState([...setup, kickBob, promoteBob]);

      expect(state.members.containsKey(bob), isFalse);
      expect(state.members[alice], GroupRole.admin);
    });
  });

  group('передача владения', () {
    test('только текущий владелец может передать владение', () {
      const transfer = OwnerTransferred(
        id: EventId('transfer-1'),
        groupId: testGroupId,
        authorId: owner,
        timestamp: 80,
        newOwnerId: alice,
      );
      final state = buildState([
        created(),
        roleSet(id: 'role-alice', userId: alice, role: GroupRole.admin),
        transfer,
      ]);

      expect(state.ownerId, alice);
      expect(state.members[alice], GroupRole.owner);
      expect(state.members[owner], GroupRole.admin);
    });

    test('не-владелец не может передать владение', () {
      const transfer = OwnerTransferred(
        id: EventId('transfer-2'),
        groupId: testGroupId,
        authorId: alice,
        timestamp: 80,
        newOwnerId: bob,
      );
      final state = buildState([
        created(),
        roleSet(id: 'role-alice', userId: alice, role: GroupRole.admin),
        transfer,
      ]);

      expect(state.ownerId, owner);
    });
  });
}
