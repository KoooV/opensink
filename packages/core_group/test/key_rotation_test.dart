import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

GroupController createController(InMemoryGroupKeyDistributor distributor) =>
    GroupController(
      distributor: distributor,
      expectedGroupId: testGroupId,
      genesisEventId: const EventId('create'),
    );

void main() {
  test(
    'удаление участника повышает эпоху и рассылает ключ оставшимся',
    () async {
      final distributor = InMemoryGroupKeyDistributor();
      final controller = createController(distributor);
      final keyPackage = Uint8List.fromList([1, 2, 3]);

      await controller.apply(created());
      await controller.apply(
        roleSet(
          id: 'role-alice',
          userId: alice,
          role: GroupRole.admin,
          prevId: const EventId('create'),
        ),
      );
      final result = await controller.apply(
        removed(id: 'kick-bob', authorId: alice, userId: bob),
        localPeerId: alice,
        keyPackage: keyPackage,
      );

      expect(result.isOk, isTrue);
      expect(controller.state.keyEpoch, 2);
      expect(controller.state.members.containsKey(bob), isFalse);
      expect(distributor.rotations, hasLength(1));

      final rotation = distributor.rotations.single;
      expect(rotation.groupId, testGroupId);
      expect(rotation.epoch, 2);
      expect(rotation.sender, alice);
      expect(rotation.recipients, {owner});
      expect(rotation.recipients.contains(bob), isFalse);
      expect(rotation.keyPackage, keyPackage);
    },
  );

  test('ручная KeyRotated двигает эпоху вперёд', () async {
    final distributor = InMemoryGroupKeyDistributor();
    final controller = createController(distributor);

    await controller.apply(created());
    final result = await controller.apply(
      keyRotated(
        id: 'rotate-manual',
        newEpoch: 5,
        timestamp: 20,
        prevId: const EventId('create'),
      ),
      localPeerId: owner,
    );

    expect(result.isOk, isTrue);
    expect(controller.state.keyEpoch, 5);
    expect(distributor.rotations, hasLength(1));
    expect(distributor.rotations.single.recipients, {alice, bob});
  });

  test('эпоху нельзя откатить назад', () async {
    final distributor = InMemoryGroupKeyDistributor();
    final controller = createController(distributor);

    await controller.apply(created());
    final result = await controller.apply(
      keyRotated(
        id: 'rotate-back',
        newEpoch: 1,
        timestamp: 20,
        prevId: const EventId('create'),
      ),
    );

    expect(result.isErr, isTrue);
    expect(result.unwrapErr(), isA<InvalidKeyEpoch>());
    expect(controller.state.keyEpoch, 1);
    expect(distributor.rotations, isEmpty);
  });
}
