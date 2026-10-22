import 'package:core_domain/core_domain.dart';
import 'package:test/test.dart';

import 'package:core_storage/core_storage.dart';
import 'memory_database.dart';

/// Валидный hex-автор (32 байта Ed25519 = 64 hex-символа).
const String _kAuthor = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

void main() {
  group('DriftEventStore', () {
    late AppDatabase db;
    late DriftEventStore store;

    setUp(() {
      db = createMemoryDatabase();
      store = DriftEventStore(db);
    });

    tearDown(() async {
      await store.close();
    });

    test('write stores an event and returns it via watchGroup', () async {
      const record = EventRecord(
        id: 'event-1',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [1, 2, 3],
        timestamp: 1000,
        signature: 'sig-hex',
      );

      final result = await store.write(record);
      expect(result.isOk, isTrue);
      expect(result.unwrap().inserted, isTrue);
      expect(result.unwrap().duplicate, isFalse);

      final events = <EventRecord>[];
      await for (final e in store.watchGroup(const GroupId('group-1')).take(1)) {
        events.add(e);
      }

      expect(events, hasLength(1));
      expect(events.first.id, 'event-1');
      expect(events.first.groupId.value, 'group-1');
      expect(events.first.author, _kAuthor);
      expect(events.first.payload, const [1, 2, 3]);
      expect(events.first.timestamp, 1000);
      expect(events.first.signature, 'sig-hex');
    });

    test('write preserves channelId for channel queries', () async {
      const record = EventRecord(
        id: 'event-channel',
        groupId: GroupId('group-1'),
        channelId: ChannelId('channel-1'),
        author: _kAuthor,
        payload: [4, 5, 6],
        timestamp: 1100,
        signature: 'sig-hex',
      );

      final result = await store.write(record);
      expect(result.unwrap().inserted, isTrue);

      final channelPage = await db.channelPage(
        groupId: 'group-1',
        channelId: 'channel-1',
      );
      expect(channelPage.events, hasLength(1));
      expect(channelPage.events.single.id, record.id);
      expect(channelPage.events.single.channelId, 'channel-1');

      final groupPage = await db.channelPage(groupId: 'group-1');
      expect(groupPage.events, isEmpty);
    });

    test('write is idempotent: same id inserted twice = one row', () async {
      const record = EventRecord(
        id: 'event-dup',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [1],
        timestamp: 1000,
        signature: 'sig-a',
      );

      final first = await store.write(record);
      expect(first.unwrap().inserted, isTrue);

      final second = await store.write(record);
      expect(second.unwrap().inserted, isFalse);
      expect(second.unwrap().duplicate, isTrue);

      final events = <EventRecord>[];
      await for (final e in store.watchGroup(const GroupId('group-1')).take(1)) {
        events.add(e);
      }

      expect(events, hasLength(1));
    });

    test('write with same id but different bytes keeps original bytes', () async {
      const firstRecord = EventRecord(
        id: 'event-same-id',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [1],
        timestamp: 1000,
        signature: 'sig-a',
      );
      const secondRecord = EventRecord(
        id: 'event-same-id',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [9, 9, 9],
        timestamp: 2000,
        signature: 'sig-b',
      );

      await store.write(firstRecord);
      final second = await store.write(secondRecord);
      expect(second.unwrap().inserted, isFalse);
      expect(second.unwrap().duplicate, isTrue);

      final found = await store.getEvent('event-same-id');
      expect(found, isNotNull);
      expect(found!.payload, const [1]); // original bytes preserved
    });

    test('getEvent retrieves a single event by id', () async {
      const record = EventRecord(
        id: 'event-get',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [9, 9, 9],
        timestamp: 2000,
        signature: 'sig-get',
      );

      await store.write(record);

      final found = await store.getEvent('event-get');
      expect(found, isNotNull);
      expect(found!.id, 'event-get');
      expect(found.author, _kAuthor);
      expect(found.payload, const [9, 9, 9]);

      final missing = await store.getEvent('nonexistent');
      expect(missing, isNull);
    });

    test('watchFrom emits new writes after subscription', () async {
      final received = <EventRecord>[];
      final subscription = store.watchFrom('cursor').listen(received.add);

      const record = EventRecord(
        id: 'event-new',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [7],
        timestamp: 3000,
        signature: 'sig-new',
      );
      await store.write(record);

      await Future.delayed(Duration.zero); // allow stream delivery

      expect(received, hasLength(1));
      expect(received.first.id, 'event-new');

      await subscription.cancel();
    });

    test('watchFrom replays history from cursor inclusive, then live', () async {
      await store.write(const EventRecord(
        id: 'event-cursor-1',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [1],
        timestamp: 1000,
        signature: 'sig-1',
      ));
      await store.write(const EventRecord(
        id: 'event-cursor-2',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [2],
        timestamp: 2000,
        signature: 'sig-2',
      ));

      final received = <EventRecord>[];
      final subscription = store
          .watchFrom('event-cursor-1')
          .listen(received.add);

      await store.write(const EventRecord(
        id: 'event-cursor-3',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [3],
        timestamp: 3000,
        signature: 'sig-3',
      ));

      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(
        received.map((event) => event.id),
        ['event-cursor-1', 'event-cursor-2', 'event-cursor-3'],
      );

      await subscription.cancel();
    });

    test('watchGroup does not lose a write during history replay', () async {
      await store.write(const EventRecord(
        id: 'event-before-subscribe',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [0],
        timestamp: 1000,
        signature: 'sig-old',
      ));

      final received = <EventRecord>[];
      final subscription = store
          .watchGroup(const GroupId('group-1'))
          .listen(received.add);

      await store.write(const EventRecord(
        id: 'event-during-replay',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [1],
        timestamp: 2000,
        signature: 'sig-new',
      ));

      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(
        received.map((event) => event.id),
        ['event-before-subscribe', 'event-during-replay'],
      );

      await subscription.cancel();
    });

    test('watchGroup emits historical events then new writes', () async {
      // Pre-existing event
      await store.write(const EventRecord(
        id: 'event-old',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [0],
        timestamp: 1000,
        signature: 'sig-old',
      ));

      final received = <EventRecord>[];
      final subscription = store.watchGroup(const GroupId('group-1')).listen(
        received.add,
        cancelOnError: false,
      );

      // New event after subscription
      await store.write(const EventRecord(
        id: 'event-new2',
        groupId: GroupId('group-1'),
        author: _kAuthor,
        payload: [1],
        timestamp: 2000,
        signature: 'sig-new2',
      ));

      await Future.delayed(Duration.zero);

      expect(received.map((e) => e.id), containsAll(['event-old', 'event-new2']));

      await subscription.cancel();
    });

    test('events for different groups are isolated', () async {
      await store.write(const EventRecord(
        id: 'e1',
        groupId: GroupId('group-a'),
        author: _kAuthor,
        payload: [1],
        timestamp: 1000,
        signature: 's1',
      ));
      await store.write(const EventRecord(
        id: 'e2',
        groupId: GroupId('group-b'),
        author: _kAuthor,
        payload: [2],
        timestamp: 1000,
        signature: 's2',
      ));

      final groupA = <EventRecord>[];
      await for (final e in store.watchGroup(const GroupId('group-a')).take(1)) {
        groupA.add(e);
      }

      expect(groupA, hasLength(1));
      expect(groupA.first.id, 'e1');
    });

    test('close releases resources', () async {
      await store.close();
      // Should not throw on second close
      await store.close();
    });
  });
}
