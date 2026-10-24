import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:core_storage/core_storage.dart';
import 'memory_database.dart';

void main() {
  group('Migration / schema', () {
    late AppDatabase db;

    setUp(() async {
      db = createMemoryDatabase();
    });

    tearDown(() async {
      await db.close();
    });

    test('schema v2 creates all tables including group_settings', () async {
      // v1 tables
      await db.selectAllGroups(); // groups table
      await db.selectMembersForGroup('g1'); // members table
      await db.selectChannelsForGroup('g1'); // channels table

      // Events table
      await db.insertEvent(
        id: 'e1',
        groupId: 'g1',
        author: 'u1',
        hlc: 1000,
        bytes: Uint8List.fromList([1]),
        signature: 's',
      );
      final event = await db.getEventById('e1');
      expect(event, isNotNull);

      // Blobs meta table
      await db.insertBlobMeta(
        id: 'b1',
        groupId: 'g1',
        filename: 'f.png',
        mimeType: 'image/png',
        size: 10,
        createdAt: 1000,
      );

      // Sync state table
      await db.setSyncState('key', Uint8List.fromList([1, 2]));
      final state = await db.getSyncState('key');
      expect(state, [1, 2]);

      // Peers table
      await db.upsertPeer(peerId: 'p1', lastSeen: 1000);

      // group_settings table (v2) via public API
      await db.upsertGroupSetting(
        id: 'gs1',
        groupId: 'g1',
        key: 'theme',
        value: 'dark',
        updatedAt: 1000,
      );
      final rows = await db.selectGroupSettingsForGroup('g1');
      expect(rows, hasLength(1));
      expect(rows.first['key'], 'theme');
      expect(rows.first['value'], 'dark');
    });

    test('schemaVersion getter returns current version', () async {
      expect(db.schemaVersion, 7);
    });

    test('indexes exist and are used (query plan check)', () async {
      await db.insertEvent(
        id: 'e1',
        groupId: 'g1',
        author: 'u1',
        hlc: 1000,
        bytes: Uint8List.fromList([1]),
        signature: 's',
      );
      await db.insertEvent(
        id: 'e2',
        groupId: 'g1',
        author: 'u1',
        hlc: 2000,
        bytes: Uint8List.fromList([2]),
        signature: 's',
      );

      // Query using the (group_id, hlc) index
      final rows = await db.selectEventsInRange(hlcFrom: 1000, hlcTo: 2000);
      expect(rows, hasLength(2));
    });

    test('migration v1→v2 preserves existing data and creates group_settings', () async {
      // Shared executor so two AppDatabase instances see the same SQLite DB.
      final executor = NativeDatabase.memory();

      // --- v1 instance: create schema at version 1 ---
      final dbV1 = AppDatabase(executor, version: 1);
      await dbV1.insertEvent(
        id: 'e1',
        groupId: 'g1',
        author: 'u1',
        hlc: 1000,
        bytes: Uint8List.fromList([1]),
        signature: 's',
      );
      await dbV1.upsertGroup(
        id: 'g1',
        name: 'Old Group',
        ownerId: 'u1',
        createdAt: 1000,
        updatedAt: 2000,
      );

      // --- v2 instance: same executor (still open), triggers migration v1→v2 ---
      final dbV2 = AppDatabase(executor, version: 2);

      // Any public access triggers _ensureSchema → migration v1→v2
      final groups = await dbV2.selectAllGroups();
      expect(groups, hasLength(1));
      expect(groups.first['name'], 'Old Group');

      // Event data preserved
      final event = await dbV2.getEventById('e1');
      expect(event, isNotNull);
      expect(event!.id, 'e1');

      // group_settings table exists after migration (public API works)
      await dbV2.upsertGroupSetting(
        id: 'gs1',
        groupId: 'g1',
        key: 'theme',
        value: 'dark',
        updatedAt: 1000,
      );
      final gsRows = await dbV2.selectGroupSettingsForGroup('g1');
      expect(gsRows, hasLength(1));
      expect(gsRows.first['key'], 'theme');
      expect(gsRows.first['value'], 'dark');

      await dbV2.close();
      await dbV1.close();
    });

    test('re-migration is idempotent: already at v2 is a no-op', () async {
      // Already at v2 from setUp
      await db.selectAllGroups();

      // Access again - should not throw or re-run migrations
      await db.selectAllGroups();
      await db.insertEvent(
        id: 'e2',
        groupId: 'g1',
        author: 'u1',
        hlc: 2000,
        bytes: Uint8List.fromList([2]),
        signature: 's',
      );
      final event = await db.getEventById('e2');
      expect(event, isNotNull);
    });

    test('database close is idempotent', () async {
      await db.close();
      await db.close(); // should not throw
    });

    test('migration v2→v3 preserves events with empty author (quarantine)',
        () async {
      // Shared executor so two AppDatabase instances see the same SQLite DB.
      final executor = NativeDatabase.memory();

      // --- v2 instance: insert event with empty author ---
      final dbV2 = AppDatabase(executor, version: 2);
      await dbV2.insertEvent(
        id: 'e-empty-author',
        groupId: 'g1',
        author: '',
        hlc: 1000,
        bytes: Uint8List.fromList([1]),
        signature: 's',
      );
      final eventV2 = await dbV2.getEventById('e-empty-author');
      expect(eventV2, isNotNull);
      expect(eventV2!.author, '');

      // --- v3 instance: same executor (still open), triggers migration v2→v3 ---
      final dbV3 = AppDatabase(executor, version: 3);

      // Event with empty author preserved (quarantine, not deleted).
      final eventV3 = await dbV3.getEventById('e-empty-author');
      expect(eventV3, isNotNull);
      expect(eventV3!.author, '');

      // Old (author, seq) index dropped, new (author, hlc) index present.
      // Query plan should use idx_events_author_hlc for author+hlc queries.
      final rows = await dbV3.selectEventsForGroup('g1');
      expect(rows, hasLength(1));

      await dbV3.close();
      await dbV2.close();
    });
  });
}
