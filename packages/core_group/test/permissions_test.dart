import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('права участников', () {
    test('member не может кикать, создавать канал или переименовывать', () {
      final setup = <GroupEvent>[
        created(initialMembers: {owner, alice}),
        added(id: 'add-carol', userId: carol),
      ];
      final state = buildState(setup);

      expect(
        state.apply(removed(authorId: carol, userId: alice)).unwrapErr(),
        isA<Forbidden>(),
      );
      expect(
        state.apply(channelCreated(authorId: carol, timestamp: 20)).unwrapErr(),
        isA<Forbidden>(),
      );
      expect(
        state.apply(renamed(authorId: carol, timestamp: 20)).unwrapErr(),
        isA<Forbidden>(),
      );
    });

    test('moderator кикает member, но не admin', () {
      final setup = <GroupEvent>[
        created(initialMembers: {owner, alice, bob}),
        roleSet(id: 'role-alice', userId: alice, role: GroupRole.admin),
        roleSet(id: 'role-bob', userId: bob, role: GroupRole.moderator),
        added(id: 'add-carol', userId: carol),
      ];
      final state = buildState(setup);

      expect(
        state.apply(removed(authorId: bob, userId: alice)).unwrapErr(),
        isA<Forbidden>(),
      );
      final afterKick = state
          .apply(removed(authorId: bob, userId: carol, timestamp: 40))
          .unwrap();
      expect(afterKick.members.containsKey(carol), isFalse);
    });

    test('нельзя изменить свою роль или назначить owner', () {
      final setup = <GroupEvent>[
        created(initialMembers: {owner, alice}),
        roleSet(id: 'role-alice', userId: alice, role: GroupRole.admin),
      ];
      final state = buildState(setup);

      expect(
        state
            .apply(
              roleSet(
                id: 'self-role',
                userId: alice,
                role: GroupRole.admin,
                authorId: alice,
              ),
            )
            .unwrapErr(),
        isA<SelfTargetForbidden>(),
      );
      expect(
        state
            .apply(
              roleSet(id: 'role-owner', userId: bob, role: GroupRole.owner),
            )
            .unwrapErr(),
        isA<OwnerRoleNotAssignable>(),
      );
    });
  });

  group('права на каналы', () {
    test('view/post проверяются по минимальной роли', () {
      final state = buildState([
        created(initialMembers: {owner, alice, bob}),
        roleSet(id: 'role-bob', userId: bob, role: GroupRole.moderator),
        added(id: 'add-carol', userId: carol),
        channelCreated(
          minViewRole: GroupRole.moderator,
          minPostRole: GroupRole.moderator,
        ),
      ]);

      const channelId = ChannelId('general');
      expect(state.canView(carol, channelId), isFalse);
      expect(state.canPost(carol, channelId), isFalse);
      expect(state.canView(bob, channelId), isTrue);
      expect(state.canPost(bob, channelId), isTrue);
      expect(state.canPost(alice, channelId), isFalse);
    });

    test('канал удаляет только owner/admin', () {
      final setup = <GroupEvent>[
        created(initialMembers: {owner, alice, bob}),
        roleSet(id: 'role-bob', userId: bob, role: GroupRole.moderator),
        channelCreated(),
      ];
      final state = buildState(setup);

      expect(
        state.apply(channelDeleted(authorId: bob, timestamp: 50)).unwrapErr(),
        isA<Forbidden>(),
      );
      final deleted = state
          .apply(
            channelDeleted(
              authorId: owner,
              timestamp: 50,
              prevId: const EventId('channel-1'),
            ),
          )
          .unwrap();
      expect(deleted.channels, isEmpty);
    });
  });

  group('инварианты событий', () {
    test('пустое имя группы отклоняется', () {
      final event = GroupCreated(
        id: const EventId('bad-create'),
        groupId: testGroupId,
        authorId: owner,
        timestamp: 0,
        name: '',
        ownerId: owner,
        initialMembers: {owner},
      );
      final result = const GroupState.empty().apply(event);

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidEvent>());
    });

    test('нулевой лимит инвайта отклоняется', () {
      final result = buildState([created()])
          .apply(inviteIssued(maxUses: 0, timestamp: 11));

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidEvent>());
    });

    test('open-инвайт без лимита и срока отклоняется', () {
      final result = buildState([created()])
          .apply(inviteIssued(maxUses: null, timestamp: 11));

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidEvent>());
    });
  });
}
