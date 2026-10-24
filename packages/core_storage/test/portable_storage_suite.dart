import 'package:core_domain/core_domain.dart';
import 'package:core_storage/core_storage.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:test/test.dart';

import 'schema_v3_snapshot.dart';
import 'schema_v5_snapshot.dart';

/// Валидный hex-автор (32 байта Ed25519 = 64 hex-символа).
const String kPortableAuthor =
    '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

class _SchemaV3ExecutorUser implements QueryExecutorUser {
  @override
  int get schemaVersion => 3;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

/// Общий набор поведенческих тестов хранилища.
///
/// Один и тот же код запускается на native (VM) и в Chrome; отличаются только
/// фабрики executor-а.
void runPortableStorageSuite(
  String backendName, {
  required Future<OpenedStorage> Function() openStorage,
  required Future<QueryExecutor> Function() openRawExecutor,
}) {
  group('Portable storage ($backendName)', () {
    late OpenedStorage opened;
    late AppDatabase db;

    setUp(() async {
      opened = await openStorage();
      db = AppDatabase(opened.executor);
      await db.open(backend: 'memory', isPersistent: false);
    });

    tearDown(() async {
      await db.close();
    });

    test('schema creates all storage tables', () async {
      expect(db.schemaVersion, 7);
      expect(await db.selectAllGroups(), isEmpty);
      expect(await db.selectMembersForGroup('group'), isEmpty);
      expect(await db.selectChannelsForGroup('group'), isEmpty);
      expect(await db.selectExpiredBlobs(0), isEmpty);
      expect(await db.getSyncState('missing'), isNull);

      await db.upsertGroup(
        id: 'group',
        name: 'Group',
        ownerId: 'owner',
        createdAt: 1,
        updatedAt: 1,
      );
      await db.addMember(groupId: 'group', userId: 'member', joinedAt: 1);
      await db.upsertChannel(
        id: 'channel',
        groupId: 'group',
        name: 'general',
        type: 'text',
        createdBy: 'owner',
        createdAt: 1,
      );
      await db.upsertPeer(peerId: 'peer', lastSeen: 1);
      await db.upsertGroupSetting(
        id: 'setting',
        groupId: 'group',
        key: 'theme',
        value: 'dark',
        updatedAt: 1,
      );
      await db.insertBlobMeta(
        id: 'blob',
        groupId: 'group',
        filename: 'file.bin',
        mimeType: 'application/octet-stream',
        size: 1,
        createdAt: 1,
      );
      await db.setSyncState('cursor', const [1, 2, 3]);

      expect(await db.selectAllGroups(), hasLength(1));
      expect(await db.selectMembersForGroup('group'), hasLength(1));
      expect(await db.selectChannelsForGroup('group'), hasLength(1));
      expect(await db.selectGroupSettingsForGroup('group'), hasLength(1));
      expect(await db.getSyncState('cursor'), [1, 2, 3]);
    });

    test('event insert is idempotent and never overwrites bytes', () async {
      await db.insertEvent(
        id: 'event-1',
        groupId: 'group',
        author: kPortableAuthor,
        hlc: 100,
        bytes: const [1, 2, 3],
        signature: 'sig-1',
      );
      final second = await db.insertEvent(
        id: 'event-1',
        groupId: 'group',
        author: kPortableAuthor,
        hlc: 200,
        bytes: const [9, 9, 9],
        signature: 'sig-2',
      );

      expect(second, 0);
      final stored = await db.getEventById('event-1');
      expect(stored, isNotNull);
      expect(stored!.hlc, 100);
      expect(stored.bytes, [1, 2, 3]);
      expect(stored.signature, 'sig-1');
    });

    test('event reads are ordered by hlc then id', () async {
      for (final (id, hlc) in [('b', 100), ('a', 100), ('c', 200)]) {
        await db.insertEvent(
          id: id,
          groupId: 'group',
          author: kPortableAuthor,
          hlc: hlc,
          bytes: const [1],
          signature: 'sig-$id',
          channelId: 'channel',
        );
      }

      final group = await db.groupEvents('group');
      expect(group.map((event) => event.id), ['a', 'b', 'c']);

      final page = await db.channelPage(
        groupId: 'group',
        channelId: 'channel',
      );
      expect(page.events.map((event) => event.id), ['c', 'b', 'a']);

      final fromCursor = await db.eventsFromCursor('b');
      expect(fromCursor.map((event) => event.id), ['b', 'c']);
    });

    test('range summary counts and limits; batch paginates', () async {
      for (var i = 0; i < 5; i++) {
        await db.insertEvent(
          id: 'event-$i',
          groupId: 'group',
          author: kPortableAuthor,
          hlc: 1000 + i,
          bytes: const [1],
          signature: 'sig-$i',
        );
      }

      final summary = (await db.rangeSummary(1000, 1004)).unwrap();
      expect(summary.count, 5);
      expect(summary.rangeHash, hasLength(32));
      expect(summary.rangeHashHex, hasLength(64));

      final tooLarge = await db.rangeSummary(1000, 1004, limit: 4);
      expect(tooLarge.isErr, isTrue);
      expect(tooLarge.unwrapErr(), isA<RangeTooLarge>());

      final first = await db.batchEvents(
        hlcFrom: 1000,
        hlcTo: 1004,
        limit: 2,
      );
      final second = await db.batchEvents(
        hlcFrom: 1000,
        hlcTo: 1004,
        limit: 2,
        offset: 2,
      );
      expect(first.map((event) => event.id), ['event-0', 'event-1']);
      expect(second.map((event) => event.id), ['event-2', 'event-3']);
    });

    test('channel pagination reports hasMore exactly', () async {
      for (var i = 0; i < 10; i++) {
        await db.insertEvent(
          id: 'event-$i',
          groupId: 'group',
          author: kPortableAuthor,
          hlc: i,
          bytes: const [1],
          signature: 'sig-$i',
          channelId: 'channel',
        );
      }

      final fullPage = await db.channelPage(
        groupId: 'group',
        channelId: 'channel',
        page: 1,
        pageSize: 10,
      );
      expect(fullPage.events, hasLength(10));
      expect(fullPage.hasMore, isFalse);
      expect(fullPage.nextPage, isNull);

      final smallPage = await db.channelPage(
        groupId: 'group',
        channelId: 'channel',
        page: 1,
        pageSize: 4,
      );
      expect(smallPage.events, hasLength(4));
      expect(smallPage.hasMore, isTrue);
      expect(smallPage.nextPage, 2);
    });

    test('event store writes, validates, and watches', () async {
      final store = DriftEventStore(db);
      addTearDown(store.close);

      const record = EventRecord(
        id: 'store-event',
        groupId: GroupId('group'),
        author: kPortableAuthor,
        payload: [1, 2, 3],
        timestamp: 100,
        signature: 'sig',
      );

      final inserted = await store.write(record);
      expect(inserted.unwrap().inserted, isTrue);

      final duplicate = await store.write(
        EventRecord(
          id: record.id,
          groupId: record.groupId,
          author: record.author,
          payload: const [9],
          timestamp: 200,
          signature: 'other',
        ),
      );
      expect(duplicate.unwrap().duplicate, isTrue);

      final restored = await store.getEvent(record.id);
      expect(restored?.payload, [1, 2, 3]);

      final invalid = await store.write(
        const EventRecord(
          id: 'invalid',
          groupId: GroupId('group'),
          author: 'not-hex',
          payload: [1],
          timestamp: 1,
          signature: 'sig',
        ),
      );
      expect(invalid.unwrapErr(), isA<InvalidAuthor>());
      expect(await store.getEvent('invalid'), isNull);
    });

    test('watchFrom replays from cursor and then emits live writes', () async {
      final store = DriftEventStore(db);
      addTearDown(store.close);

      for (var i = 1; i <= 3; i++) {
        await store.write(
          EventRecord(
            id: 'event-$i',
            groupId: const GroupId('group'),
            author: kPortableAuthor,
            payload: [i],
            timestamp: i,
            signature: 'sig-$i',
          ),
        );
      }

      final received = store.watchFrom('event-2').take(3).toList();
      await store.write(
        const EventRecord(
          id: 'event-4',
          groupId: GroupId('group'),
          author: kPortableAuthor,
          payload: [4],
          timestamp: 4,
          signature: 'sig-4',
        ),
      );

      final events = await received.timeout(const Duration(seconds: 5));
      expect(events.map((event) => event.id), ['event-2', 'event-3', 'event-4']);
    });

    test('retention deletes file before metadata and keeps failed rows', () async {
      await db.insertBlobMeta(
        id: 'expired',
        groupId: 'group',
        filename: 'expired.bin',
        mimeType: 'application/octet-stream',
        size: 1,
        createdAt: 1,
        expiresAt: 1,
      );
      await db.insertBlobMeta(
        id: 'failed',
        groupId: 'group',
        filename: 'failed.bin',
        mimeType: 'application/octet-stream',
        size: 1,
        createdAt: 1,
        expiresAt: 1,
      );

      final retention = RetentionPolicy(db);
      final deleted = <String>[];
      final result = await retention.run(
        2,
        deleteBlob: (blob) async {
          if (blob.id == 'failed') {
            throw StateError('locked');
          }
          deleted.add(blob.id);
        },
      );

      expect(deleted, ['expired']);
      expect(result.deleted, 1);
      expect(result.failures.single.blob.id, 'failed');
      expect(await db.selectExpiredBlobs(2), hasLength(1));
    });

    test('query plans use group/hlc and author/hlc indexes', () async {
      for (var i = 0; i < 16; i++) {
        await db.insertEvent(
          id: 'event-$i',
          groupId: 'group-${i % 2}',
          author: kPortableAuthor,
          hlc: i,
          bytes: const [1],
          signature: 'sig-$i',
        );
      }

      final groupPlan = await opened.executor.runSelect(
        'EXPLAIN QUERY PLAN SELECT id FROM events '
        'WHERE group_id = ? AND hlc BETWEEN ? AND ? ORDER BY hlc ASC',
        ['group-1', 0, 15],
      );
      final authorPlan = await opened.executor.runSelect(
        'EXPLAIN QUERY PLAN SELECT id FROM events '
        'WHERE author = ? AND hlc BETWEEN ? AND ? ORDER BY hlc ASC',
        [kPortableAuthor, 0, 15],
      );

      expect(
        groupPlan.map((row) => row['detail'].toString()).join(' '),
        contains('idx_events_group_hlc'),
      );
      expect(
        authorPlan.map((row) => row['detail'].toString()).join(' '),
        contains('idx_events_author_hlc'),
      );
    });

    test('fresh install has append-only triggers', () async {
      await db.insertEvent(
        id: 'immutable',
        groupId: 'group',
        author: kPortableAuthor,
        hlc: 1,
        bytes: const [1],
        signature: 'sig',
      );

      await expectLater(
        opened.executor.runUpdate(
          "UPDATE events SET signature = 'changed' WHERE id = ?",
          ['immutable'],
        ),
        throwsA(anything),
      );
      await expectLater(
        opened.executor.runDelete(
          'DELETE FROM events WHERE id = ?',
          ['immutable'],
        ),
        throwsA(anything),
      );
    });
  });

  group('Portable migrations ($backendName)', () {
    late QueryExecutor executor;

    setUp(() async {
      executor = await openRawExecutor();
      await executor.ensureOpen(_SchemaV3ExecutorUser());
      addTearDown(() async {
        try {
          await executor.close();
        } on Object {
          // executor мог быть закрыт через AppDatabase.
        }
      });
    });

    test('v3 to v7 preserves events and installs append-only triggers', () async {
      for (final statement in schemaV3Snapshot) {
        await executor.runCustom(statement);
      }
      await executor.runInsert(
        'INSERT INTO schema_info (id, version) VALUES (1, 3)',
        const [],
      );
      await executor.runInsert(
        'INSERT INTO events (id, group_id, author, hlc, bytes, signature) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          'known',
          'group',
          kPortableAuthor,
          100,
          const [1],
          'sig-known',
        ],
      );
      await executor.runInsert(
        'INSERT INTO events (id, group_id, author, hlc, bytes, signature) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        ['quarantined', 'group', '', 200, const [2], 'sig-quarantined'],
      );

      final migrated = AppDatabase(executor);
      try {
        expect((await migrated.getEventById('known'))?.author, kPortableAuthor);
        final quarantined = await migrated.getEventById('quarantined');
        expect(quarantined, isNotNull);
        expect(quarantined!.author, isEmpty);
        expect(quarantined.bytes, [2]);

        final version = await executor.runSelect(
          'SELECT version FROM schema_info WHERE id = 1',
          const [],
        );
        expect(version.single['version'], 7);
        final columns = await executor.runSelect(
          'PRAGMA table_info(events)',
          const [],
        );
        expect(columns.map((column) => column['name']), isNot(contains('seq')));

        await expectLater(
          executor.runUpdate(
            "UPDATE events SET signature = 'changed' WHERE id = ?",
            ['known'],
          ),
          throwsA(anything),
        );
      } finally {
        await migrated.close();
      }
    });

    test('v5 to v6 drops seq and preserves event payload', () async {
      for (final statement in schemaV5Snapshot) {
        await executor.runCustom(statement);
      }
      await executor.runInsert(
        'INSERT INTO schema_info (id, version) VALUES (1, 5)',
        const [],
      );
      await executor.runInsert(
        'INSERT INTO events '
        '(id, group_id, author, hlc, bytes, signature, channel_id, seq) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          'v5-event',
          'group',
          kPortableAuthor,
          100,
          const [1, 2, 3],
          'sig-v5',
          'channel',
          42,
        ],
      );

      final migrated = AppDatabase(executor);
      try {
        final event = await migrated.getEventById('v5-event');
        expect(event, isNotNull);
        expect(event!.groupId, 'group');
        expect(event.channelId, 'channel');
        expect(event.bytes, [1, 2, 3]);
        expect(event.signature, 'sig-v5');

        final columns = await executor.runSelect(
          'PRAGMA table_info(events)',
          const [],
        );
        expect(columns.map((column) => column['name']), isNot(contains('seq')));
      } finally {
        await migrated.close();
      }
    });
  });
}
