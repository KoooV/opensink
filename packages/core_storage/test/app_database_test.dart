import 'dart:typed_data';
import 'package:test/test.dart';

import 'package:core_storage/core_storage.dart';
import 'memory_database.dart';

void main() {
  group('AppDatabase', () {
    late AppDatabase db;

    setUp(() {
      db = createMemoryDatabase();
    });

    tearDown(() async {
      await db.close();
    });

    test('insertEvent and selectEventById roundtrip', () async {
      await db.insertEvent(
        id: 'e1',
        groupId: 'g1',
        author: 'user1',
        hlc: 1000,
        bytes: Uint8List.fromList([1, 2, 3]),
        signature: 'sig1',
      );

      final row = await db.selectEventById('e1');
      expect(row, isNotNull);
      expect(row!['id'], 'e1');
      expect(row['group_id'], 'g1');
      expect(row['hlc'], 1000);
    });

    test('insertOrIgnore: duplicate id does not overwrite', () async {
      await db.insertEvent(
        id: 'e1',
        groupId: 'g1',
        author: 'user1',
        hlc: 1000,
        bytes: Uint8List.fromList([1]),
        signature: 'sig1',
      );
      await db.insertEvent(
        id: 'e1',
        groupId: 'g1',
        author: 'user2',
        hlc: 2000,
        bytes: Uint8List.fromList([9]),
        signature: 'sig2',
      );

      final row = await db.selectEventById('e1');
      expect(row!['hlc'], 1000); // original value preserved
      expect(row['author'], 'user1');
    });

    test('selectEventsInRange filters by hlc and orders correctly', () async {
      await db.insertEvent(id: 'e1', groupId: 'g1', author: 'a', hlc: 100, bytes: Uint8List.fromList([1]), signature: 's');
      await db.insertEvent(id: 'e2', groupId: 'g1', author: 'a', hlc: 200, bytes: Uint8List.fromList([2]), signature: 's');
      await db.insertEvent(id: 'e3', groupId: 'g1', author: 'a', hlc: 300, bytes: Uint8List.fromList([3]), signature: 's');
      await db.insertEvent(id: 'e4', groupId: 'g1', author: 'a', hlc: 400, bytes: Uint8List.fromList([4]), signature: 's');

      final rows = await db.selectEventsInRange(hlcFrom: 150, hlcTo: 350, limit: 10);
      expect(rows, hasLength(2));
      expect(rows[0]['id'], 'e2');
      expect(rows[1]['id'], 'e3');
    });

    test('selectEventsForGroup returns events ordered by hlc ASC', () async {
      await db.insertEvent(id: 'e1', groupId: 'g1', author: 'a', hlc: 300, bytes: Uint8List.fromList([1]), signature: 's');
      await db.insertEvent(id: 'e2', groupId: 'g1', author: 'a', hlc: 100, bytes: Uint8List.fromList([2]), signature: 's');
      await db.insertEvent(id: 'e3', groupId: 'g1', author: 'a', hlc: 200, bytes: Uint8List.fromList([3]), signature: 's');

      final rows = await db.selectEventsForGroup('g1');
      expect(rows, hasLength(3));
      expect(rows[0]['id'], 'e2'); // hlc 100
      expect(rows[1]['id'], 'e3'); // hlc 200
      expect(rows[2]['id'], 'e1'); // hlc 300
    });

    test('groupEvents returns EventData objects', () async {
      await db.insertEvent(id: 'e1', groupId: 'g1', author: 'user1', hlc: 100, bytes: Uint8List.fromList([1]), signature: 's', channelId: 'ch1');

      final events = await db.groupEvents('g1');
      expect(events, hasLength(1));
      expect(events.first.id, 'e1');
      expect(events.first.channelId, 'ch1');
    });

    test('getEventById returns null for missing event', () async {
      final result = await db.getEventById('nonexistent');
      expect(result, isNull);
    });

    test('countEvents returns correct count', () async {
      await db.insertEvent(id: 'e1', groupId: 'g1', author: 'a', hlc: 100, bytes: Uint8List.fromList([1]), signature: 's');
      await db.insertEvent(id: 'e2', groupId: 'g1', author: 'a', hlc: 200, bytes: Uint8List.fromList([2]), signature: 's', channelId: 'ch1');
      await db.insertEvent(id: 'e3', groupId: 'g2', author: 'a', hlc: 300, bytes: Uint8List.fromList([3]), signature: 's');

      expect(await db.countEvents('g1'), 1); // only e1 has NULL channel_id
      expect(await db.countEvents('g1', channelId: 'ch1'), 1); // e2
      expect(await db.countEvents('g2'), 1); // e3
      expect(await db.countEvents('g3'), 0);
    });

    test('upsertGroup and selectAllGroups', () async {
      await db.upsertGroup(
        id: 'g1',
        name: 'Group One',
        ownerId: 'user1',
        createdAt: 1000,
        updatedAt: 2000,
      );
      await db.upsertGroup(
        id: 'g2',
        name: 'Group Two',
        ownerId: 'user2',
        createdAt: 1000,
        updatedAt: 2000,
      );

      final groups = await db.selectAllGroups();
      expect(groups, hasLength(2));
      expect(groups.first['name'], 'Group One');
    });

    test('members add/remove/query', () async {
      await db.addMember(groupId: 'g1', userId: 'u1', joinedAt: 1000);
      await db.addMember(groupId: 'g1', userId: 'u2', joinedAt: 2000);

      final members = await db.selectMembersForGroup('g1');
      expect(members, hasLength(2));

      await db.removeMember('g1', 'u1');
      final afterRemove = await db.selectMembersForGroup('g1');
      expect(afterRemove, hasLength(1));
      expect(afterRemove.first['user_id'], 'u2');
    });

    test('upsertChannel and selectChannelsForGroup', () async {
      await db.upsertChannel(
        id: 'ch1',
        groupId: 'g1',
        name: 'general',
        type: 'text',
        createdBy: 'user1',
        createdAt: 1000,
      );
      await db.upsertChannel(
        id: 'ch2',
        groupId: 'g1',
        name: 'voice-chat',
        type: 'voice',
        createdBy: 'user2',
        createdAt: 2000,
      );

      final channels = await db.selectChannelsForGroup('g1');
      expect(channels, hasLength(2));
    });

    test('upsertPeer', () async {
      await db.upsertPeer(peerId: 'peer1', lastSeen: 1000, address: '/ip4/127.0.0.1');
      // Should not throw on re-upsert
      await db.upsertPeer(peerId: 'peer1', lastSeen: 2000, address: null);
    });

    test('blob meta insert and expire', () async {
      await db.insertBlobMeta(
        id: 'b1',
        groupId: 'g1',
        filename: 'image.png',
        mimeType: 'image/png',
        size: 1024,
        createdAt: 1000,
        expiresAt: 5000, // expires soon
      );
      await db.insertBlobMeta(
        id: 'b2',
        groupId: 'g1',
        filename: 'doc.pdf',
        mimeType: 'application/pdf',
        size: 2048,
        createdAt: 2000,
        expiresAt: null, // never expires
      );

      final expired = await db.selectExpiredBlobs(6000);
      expect(expired, hasLength(1));
      expect(expired.first['id'], 'b1');

      final deleted = await db.expireBlobs(6000);
      expect(deleted, 1);

      final remaining = await db.selectExpiredBlobs(6000);
      expect(remaining, isEmpty);
    });

    test('sync state set/get', () async {
      await db.setSyncState('cursor', Uint8List.fromList([1, 2, 3, 4]));
      final value = await db.getSyncState('cursor');
      expect(value, isNotNull);
      expect(value, [1, 2, 3, 4]);

      final missing = await db.getSyncState('nonexistent');
      expect(missing, isNull);
    });
  });
}
