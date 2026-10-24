import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

GroupController createController() => GroupController(
  distributor: InMemoryGroupKeyDistributor(),
  expectedGroupId: testGroupId,
  genesisEventId: const EventId('create'),
  inviteProofVerifier: allowAllProofs,
);

void main() {
  group('genesis в apply', () {
    test('apply на пустом состоянии требует совпадающий корень', () {
      final result = const GroupState.empty().apply(
        created(id: 'fake'),
        expectedGroupId: testGroupId,
        genesisEventId: const EventId('create'),
      );

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<GenesisMismatch>());
    });

    test('apply без ожидаемого корня отклоняет создание', () {
      final result = const GroupState.empty().apply(created());

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<GenesisMismatch>());
    });

    test('apply принимает ожидаемый корень и запоминает его', () {
      final state = const GroupState.empty()
          .apply(
            created(),
            expectedGroupId: testGroupId,
            genesisEventId: const EventId('create'),
          )
          .unwrap();

      expect(state.genesisEventId, const EventId('create'));
    });
  });

  group('цепочка prevId в apply', () {
    late GroupState state;

    setUp(() {
      state = buildState([
        created(),
        roleSet(
          id: 'role-alice',
          userId: alice,
          role: GroupRole.admin,
          timestamp: 12,
        ),
      ]);
    });

    test('prevId чужого автора отклоняется', () {
      final forged = renamed(
        id: 'forged',
        authorId: alice,
        timestamp: 20,
        prevId: const EventId('role-alice'),
      );

      expect(state.apply(forged).unwrapErr(), isA<EventChainBroken>());
    });

    test('HLC не меньше HLC prev', () {
      final backdated = renamed(
        id: 'backdated',
        timestamp: 5,
        prevId: const EventId('role-alice'),
      );

      expect(state.apply(backdated).unwrapErr(), isA<EventChainBroken>());
    });

    test('второй корень автора отклоняется', () {
      final secondRoot = renamed(id: 'second-root', timestamp: 20);

      expect(state.apply(secondRoot).unwrapErr(), isA<EventChainBroken>());
    });

    test('неизвестный prevId отклоняется', () {
      final orphan = renamed(
        id: 'orphan',
        timestamp: 20,
        prevId: const EventId('missing'),
      );

      expect(state.apply(orphan).unwrapErr(), isA<EventChainBroken>());
    });

    test('семантический отказ всё равно двигает курсор автора', () {
      final rejected = state.apply(
        keyRotated(
          id: 'rotate-back',
          newEpoch: 1,
          timestamp: 20,
          prevId: const EventId('role-alice'),
        ),
      );

      expect(rejected.isErr, isTrue);
      expect(rejected.unwrapErr(), isA<InvalidKeyEpoch>());

      final next = rejected.state.apply(
        renamed(
          id: 'rename',
          timestamp: 20,
          prevId: const EventId('rotate-back'),
        ),
      );

      expect(next.isOk, isTrue);
      expect(next.state.name, 'Renamed');
    });
  });

  group('genesis и цепочка в GroupController', () {
    test('чужой genesis отклоняется без изменения состояния', () async {
      final controller = createController();

      final foreign = await controller.apply(created(id: 'fake'));

      expect(foreign.isErr, isTrue);
      expect(foreign.unwrapErr(), isA<GenesisMismatch>());
      expect(controller.state.isInitialized, isFalse);
    });

    test(
      'валидный genesis принимается, битая цепочка не меняет содержимое',
      () async {
        final controller = createController();

        expect((await controller.apply(created())).isOk, isTrue);
        expect(
          (await controller.apply(
            roleSet(
              id: 'role-alice',
              userId: alice,
              role: GroupRole.admin,
              timestamp: 12,
              prevId: const EventId('create'),
            ),
          )).isOk,
          isTrue,
        );

        final before = controller.state;
        final backdated = await controller.apply(
          renamed(
            id: 'backdated',
            timestamp: 5,
            prevId: const EventId('role-alice'),
          ),
        );

        expect(backdated.isErr, isTrue);
        expect(backdated.unwrapErr(), isA<EventChainBroken>());
        expect(controller.state.name, before.name);
        expect(controller.state.members, before.members);
        expect(controller.state.keyEpoch, before.keyEpoch);
        expect(
          controller.state.cursors[owner]?.id,
          const EventId('role-alice'),
        );

        final valid = await controller.apply(
          renamed(
            id: 'rename',
            timestamp: 20,
            prevId: const EventId('role-alice'),
          ),
        );
        expect(valid.isOk, isTrue);
        expect(controller.state.name, 'Renamed');
      },
    );
  });

  group('дедупликация до фильтра группы', () {
    test('дубликат id из чужой группы не скрывает genesis', () {
      final foreign = created(
        id: 'create',
        groupId: const GroupId('evil'),
        timestamp: 0,
      );
      final real = created(id: 'create', timestamp: 1);

      final state = GroupState.fromEvents(
        [foreign, real],
        expectedGroupId: testGroupId,
        genesisEventId: const EventId('create'),
      );

      expect(state.id, testGroupId);
      expect(state.members[owner], GroupRole.owner);
      expect(state.createdAt, 1);
    });
  });

  group('порядок доставки в GroupController', () {
    test('опоздавший родитель не теряет дочернее событие', () async {
      final controller = createController();
      final role = roleSet(
        id: 'role-alice',
        userId: alice,
        role: GroupRole.admin,
        timestamp: 12,
        prevId: const EventId('create'),
      );
      final rename = renamed(
        id: 'rename',
        timestamp: 20,
        prevId: const EventId('role-alice'),
      );

      expect((await controller.apply(rename)).isOk, isTrue);
      await controller.apply(created());
      await controller.apply(role);

      expect(controller.state.name, 'Renamed');
      expect(controller.state.members[alice], GroupRole.admin);
    });

    test('форк сходится при любом порядке доставки', () async {
      final role = roleSet(
        id: 'role-alice',
        userId: alice,
        role: GroupRole.admin,
        timestamp: 10,
        prevId: const EventId('create'),
      );
      final alpha = renamed(
        id: 'alpha',
        name: 'Alpha',
        timestamp: 20,
        prevId: const EventId('role-alice'),
      );
      final beta = renamed(
        id: 'beta',
        name: 'Beta',
        timestamp: 21,
        prevId: const EventId('role-alice'),
      );

      final first = createController();
      await first.apply(created());
      await first.apply(role);
      await first.apply(beta);
      await first.apply(alpha);

      final second = createController();
      await second.apply(created());
      await second.apply(role);
      await second.apply(alpha);
      await second.apply(beta);

      expect(first.state, second.state);
      expect(first.state.name, 'Alpha');
    });

    test('любой порядок доставки сходится с fromEvents', () async {
      final events = linked([
        created(),
        inviteIssued(maxUses: 10, expiresAt: 10000),
        joined(userId: carol),
        roleSet(
          id: 'role-alice',
          userId: alice,
          role: GroupRole.admin,
          timestamp: 12,
        ),
        channelCreated(id: 'channel-general', channelId: 'general'),
        renamed(id: 'rename-main', timestamp: 17),
        removed(id: 'kick-bob', authorId: alice, userId: bob, timestamp: 40),
      ]);
      final reference = buildState(events);
      final random = Random(20261024);

      for (var run = 0; run < 100; run++) {
        final shuffled = List<GroupEvent>.of(events)..shuffle(random);
        final controller = createController();
        for (final event in shuffled) {
          final result = await controller.apply(event);
          expect(
            result.isOk,
            isTrue,
            reason:
                'run $run, event ${event.id.value} в порядке '
                '${shuffled.map((e) => e.id.value)}',
          );
        }
        expect(
          controller.state,
          reference,
          reason: 'run $run, order ${shuffled.map((e) => e.id.value)}',
        );
      }
    });

    test('курсор двигается после семантического отказа', () async {
      final controller = createController();
      await controller.apply(created());

      final rejected = await controller.apply(
        keyRotated(
          id: 'rotate-back',
          newEpoch: 1,
          timestamp: 20,
          prevId: const EventId('create'),
        ),
      );
      expect(rejected.isErr, isTrue);
      expect(rejected.unwrapErr(), isA<InvalidKeyEpoch>());

      final next = await controller.apply(
        renamed(
          id: 'rename',
          timestamp: 20,
          prevId: const EventId('rotate-back'),
        ),
      );

      expect(next.isOk, isTrue);
      expect(controller.state.name, 'Renamed');
    });
  });

  group('детерминированный порядок fromEvents', () {
    test('форк детей genesis разрешается без потери всей цепочки', () {
      final alpha = roleSet(
        id: 'a-role',
        userId: alice,
        role: GroupRole.admin,
        timestamp: 10,
        prevId: const EventId('create'),
      );
      final beta = roleSet(
        id: 'b-role',
        userId: bob,
        role: GroupRole.admin,
        timestamp: 11,
        prevId: const EventId('create'),
      );

      final state = GroupState.fromEvents(
        [created(), beta, alpha],
        expectedGroupId: testGroupId,
        genesisEventId: const EventId('create'),
      );

      expect(state.members[alice], GroupRole.admin);
      expect(state.members[bob], GroupRole.member);
    });

    test('родитель с большим id применяется раньше ребёнка при равном HLC', () {
      final parent = roleSet(
        id: 'z-parent',
        userId: alice,
        role: GroupRole.admin,
        timestamp: 10,
        prevId: const EventId('create'),
      );
      final child = renamed(
        id: 'a-child',
        timestamp: 10,
        prevId: const EventId('z-parent'),
      );

      final state = GroupState.fromEvents(
        [created(), parent, child],
        expectedGroupId: testGroupId,
        genesisEventId: const EventId('create'),
      );

      expect(state.name, 'Renamed');
      expect(state.members[alice], GroupRole.admin);
    });
  });

  group('дедупликация по телу', () {
    test('apply отклоняет другой body для уже применённого id', () {
      final state = buildState([created()]);
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

      final applied = state.apply(alpha);
      expect(applied.isOk, isTrue);

      final result = applied.state.apply(beta);

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<EventIdCollision>());
    });

    test('GroupController сходится при разном порядке тел одного id', () async {
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

      final first = createController();
      await first.apply(created());
      await first.apply(beta);
      await first.apply(alpha);

      final second = createController();
      await second.apply(created());
      await second.apply(alpha);
      await second.apply(beta);

      expect(first.state, second.state);
      expect(first.state.name, 'Alpha');
    });
  });

  group('курсоры в публичной фабрике', () {
    test('состояние можно восстановить и продолжить цепочку', () {
      final original = buildState([
        created(),
        roleSet(
          id: 'role-alice',
          userId: alice,
          role: GroupRole.admin,
          timestamp: 12,
          prevId: const EventId('create'),
        ),
      ]);
      final restored = GroupState(
        id: original.id,
        name: original.name,
        ownerId: original.ownerId,
        members: original.members,
        channels: original.channels,
        invites: original.invites,
        pendingJoins: original.pendingJoins,
        keyEpoch: original.keyEpoch,
        createdAt: original.createdAt,
        updatedAt: original.updatedAt,
        appliedEventIds: original.appliedEventIds,
        genesisEventId: original.genesisEventId,
        cursors: original.cursors,
        eventFingerprints: original.eventFingerprints,
      );

      expect(restored, original);

      final next = restored.apply(
        renamed(
          id: 'rename',
          timestamp: 20,
          prevId: const EventId('role-alice'),
        ),
      );

      expect(next.isOk, isTrue);
      expect(next.state.name, 'Renamed');
    });

    test('несогласованный снапшот отклоняется', () {
      final original = buildState([created()]);

      expect(
        () => GroupState(
          id: original.id,
          name: original.name,
          ownerId: original.ownerId,
          members: original.members,
          channels: original.channels,
          invites: original.invites,
          pendingJoins: original.pendingJoins,
          keyEpoch: original.keyEpoch,
          createdAt: original.createdAt,
          updatedAt: original.updatedAt,
          appliedEventIds: original.appliedEventIds,
          genesisEventId: original.genesisEventId,
        ),
        throwsArgumentError,
      );
    });
  });

  group('журнал и устойчивость GroupController', () {
    test('переполнение журнала отклоняется', () async {
      final distributor = InMemoryGroupKeyDistributor();
      final controller = GroupController(
        distributor: distributor,
        expectedGroupId: testGroupId,
        genesisEventId: const EventId('create'),
        inviteProofVerifier: allowAllProofs,
        maxJournalEvents: 2,
      );

      expect((await controller.apply(created())).isOk, isTrue);
      expect(
        (await controller.apply(
          roleSet(
            id: 'role-alice',
            userId: alice,
            role: GroupRole.admin,
            timestamp: 5,
            prevId: const EventId('create'),
          ),
        )).isOk,
        isTrue,
      );

      final overflow = await controller.apply(
        renamed(
          id: 'rename',
          timestamp: 20,
          prevId: const EventId('role-alice'),
        ),
      );

      expect(overflow.isErr, isTrue);
      expect(overflow.unwrapErr(), isA<JournalFull>());
      expect(controller.state.name, 'Test group');
    });

    test('поздний форк не откатывает эпоху ключа', () async {
      final controller = createController();

      await controller.apply(created());
      await controller.apply(
        roleSet(
          id: 'base',
          userId: alice,
          role: GroupRole.admin,
          timestamp: 5,
          prevId: const EventId('create'),
        ),
      );
      final removal = await controller.apply(
        removed(
          id: 'remove-bob',
          userId: bob,
          timestamp: 40,
          prevId: const EventId('base'),
        ),
      );
      expect(removal.isOk, isTrue);
      expect(controller.state.keyEpoch, 2);

      final lateFork = await controller.apply(
        renamed(
          id: 'early-rename',
          timestamp: 20,
          prevId: const EventId('base'),
        ),
      );

      expect(lateFork.isErr, isTrue);
      expect(lateFork.unwrapErr(), isA<StateRegression>());
      expect(controller.state.keyEpoch, 2);
      expect(controller.state.members.containsKey(bob), isFalse);
    });

    test('genesis с чужим owner не инициализирует группу', () async {
      final controller = createController();
      final invalid = GroupCreated(
        id: const EventId('create'),
        groupId: testGroupId,
        authorId: alice,
        timestamp: 0,
        name: 'Evil',
        ownerId: owner,
        initialMembers: {owner, alice, bob},
      );

      final result = await controller.apply(invalid);

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<Forbidden>());
      expect(controller.state.isInitialized, isFalse);
    });

    test('genesis-дубликаты канонизируются после инициализации', () async {
      GroupCreated genesis(String name) => GroupCreated(
        id: const EventId('create'),
        groupId: testGroupId,
        authorId: owner,
        timestamp: 0,
        name: name,
        ownerId: owner,
        initialMembers: {owner, alice, bob},
      );

      final first = createController();
      final second = createController();
      final alpha = genesis('Alpha');
      final beta = genesis('Beta');

      expect((await first.apply(beta)).isOk, isTrue);
      expect((await first.apply(alpha)).isOk, isTrue);
      expect((await second.apply(alpha)).isOk, isTrue);
      expect((await second.apply(beta)).isOk, isTrue);

      expect(first.state, second.state);
      expect(first.state.name, 'Alpha');
    });

    test('ротация из буфера атрибутируется своему автору', () async {
      final distributor = InMemoryGroupKeyDistributor();
      final controller = GroupController(
        distributor: distributor,
        expectedGroupId: testGroupId,
        genesisEventId: const EventId('create'),
        inviteProofVerifier: allowAllProofs,
      );

      await controller.apply(created());
      await controller.apply(
        roleSet(
          id: 'grant-alice',
          userId: alice,
          role: GroupRole.admin,
          timestamp: 5,
          prevId: const EventId('create'),
        ),
      );

      final rotate = keyRotated(
        id: 'alice-rotate',
        newEpoch: 2,
        authorId: alice,
        timestamp: 30,
        prevId: const EventId('alice-rename'),
      );
      final rename = renamed(
        id: 'alice-rename',
        authorId: alice,
        timestamp: 20,
      );

      expect((await controller.apply(rotate)).isOk, isTrue);
      expect(
        (await controller.apply(
          rename,
          keyPackage: Uint8List.fromList([9, 9]),
        )).isOk,
        isTrue,
      );

      final rotation = distributor.rotations.single;
      expect(rotation.epoch, 2);
      expect(rotation.sender, alice);
      expect(rotation.keyPackage, isEmpty);
    });

    test('конкурентные apply рассылают эпохи по порядку', () async {
      final distributor = _GatedDistributor();
      final controller = GroupController(
        distributor: distributor,
        expectedGroupId: testGroupId,
        genesisEventId: const EventId('create'),
        inviteProofVerifier: allowAllProofs,
      );

      await controller.apply(created());
      await controller.apply(
        roleSet(
          id: 'grant-alice',
          userId: alice,
          role: GroupRole.admin,
          timestamp: 5,
          prevId: const EventId('create'),
        ),
      );

      final kick = controller.apply(
        removed(
          id: 'kick-bob',
          userId: bob,
          timestamp: 40,
          prevId: const EventId('grant-alice'),
        ),
      );
      final rotate = controller.apply(
        keyRotated(
          id: 'manual-rotate',
          newEpoch: 3,
          timestamp: 50,
          prevId: const EventId('kick-bob'),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(distributor.epochs, [2]);
      distributor.gate.complete();

      expect((await kick).isOk, isTrue);
      expect((await rotate).isOk, isTrue);
      expect(distributor.epochs, [2, 3]);
      expect(controller.state.keyEpoch, 3);
    });
  });
}

class _GatedDistributor implements GroupKeyDistributor {
  final Completer<void> gate = Completer<void>();
  final List<int> epochs = [];
  bool _blocked = false;

  @override
  Future<void> distribute(GroupKeyRotation rotation) async {
    epochs.add(rotation.epoch);
    if (!_blocked) {
      _blocked = true;
      await gate.future;
    }
  }
}
