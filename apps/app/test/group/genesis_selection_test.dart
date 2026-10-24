import 'package:app/di/providers.dart';
import 'package:app/group/genesis_selection.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SyncEvent event({
  required String id,
  required SyncEventKind kind,
  int physicalMs = 0,
  int counter = 0,
}) {
  return SyncEvent(
    id: EventId(id),
    groupId: const GroupId('group-1'),
    authorId: const UserId('author'),
    hlc: Hlc(physicalMs, counter),
    kind: kind,
  );
}

void main() {
  group('selectGenesis', () {
    test('пустой лог не содержит genesis', () {
      final selection = selectGenesis([
        event(id: 'message', kind: SyncEventKind.messageCreated),
      ]);

      expect(selection.genesis, isNull);
      expect(selection.duplicateCount, 0);
    });

    test('выбирает самый ранний GroupCreated независимо от порядка', () {
      final later = event(
        id: 'later',
        kind: SyncEventKind.groupCreated,
        physicalMs: 20,
      );
      final earlier = event(
        id: 'earlier',
        kind: SyncEventKind.groupCreated,
        physicalMs: 10,
      );

      final selection = selectGenesis([later, earlier]);

      expect(selection.genesis?.id, const EventId('earlier'));
      expect(selection.duplicateCount, 1);
    });

    test('при равном HLC выбирает меньший id и считает дубли', () {
      final selection = selectGenesis([
        event(id: 'b', kind: SyncEventKind.groupCreated, physicalMs: 10),
        event(id: 'a', kind: SyncEventKind.groupCreated, physicalMs: 10),
        event(id: 'c', kind: SyncEventKind.groupCreated, physicalMs: 10),
      ]);

      expect(selection.genesis?.id, const EventId('a'));
      expect(selection.duplicateCount, 2);
    });
  });

  group('activeGroupIdProvider', () {
    test('дефолт и явная смена активной группы', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(activeGroupIdProvider), const GroupId('main'));

      container.read(activeGroupIdProvider.notifier).state = const GroupId(
        'other',
      );

      expect(container.read(activeGroupIdProvider), const GroupId('other'));
    });
  });
}
