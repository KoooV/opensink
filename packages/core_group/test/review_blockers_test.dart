import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

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
  });

  group('genesis и цепочка в GroupController', () {
    test('чужой genesis отклоняется без изменения состояния', () async {
      final controller = GroupController(
        distributor: InMemoryGroupKeyDistributor(),
        expectedGroupId: testGroupId,
        genesisEventId: const EventId('create'),
      );

      final foreign = await controller.apply(created(id: 'fake'));

      expect(foreign.isErr, isTrue);
      expect(foreign.unwrapErr(), isA<GenesisMismatch>());
      expect(controller.state.isInitialized, isFalse);
    });

    test('валидный genesis принимается, битая цепочка не мутирует', () async {
      final controller = GroupController(
        distributor: InMemoryGroupKeyDistributor(),
        expectedGroupId: testGroupId,
        genesisEventId: const EventId('create'),
      );

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
      expect(controller.state, before);

      final valid = await controller.apply(
        renamed(
          id: 'rename',
          timestamp: 20,
          prevId: const EventId('role-alice'),
        ),
      );
      expect(valid.isOk, isTrue);
      expect(controller.state.name, 'Renamed');
    });
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
}
