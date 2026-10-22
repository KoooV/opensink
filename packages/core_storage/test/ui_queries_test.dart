import 'package:test/test.dart';

import 'package:core_storage/core_storage.dart';
import 'memory_database.dart';

void main() {
  group('UiQueries (channel pagination)', () {
    late AppDatabase db;

    setUp(() {
      db = createMemoryDatabase();
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> seedChannelEvents({
      required String groupId,
      required String? channelId,
      required int count,
      required int baseHlc,
    }) async {
      for (var i = 0; i < count; i++) {
        await db.insertEvent(
          id: 'evt-$groupId-${channelId ?? 'grp'}-$i',
          groupId: groupId,
          author: 'user-$i',
          hlc: baseHlc + i,
          bytes: List.filled(5, i),
          signature: 'sig-$i',
          channelId: channelId,
        );
      }
    }

    test('channelPage returns newest first, paginated', () async {
      await seedChannelEvents(groupId: 'g1', channelId: 'ch1', count: 25, baseHlc: 1000);

      final page1 = await db.channelPage(groupId: 'g1', channelId: 'ch1', page: 1, pageSize: 10);
      expect(page1.events, hasLength(10));
      expect(page1.hasMore, isTrue);
      expect(page1.events.first.hlc, 1024); // newest first
      expect(page1.events.last.hlc, 1015);

      final page2 = await db.channelPage(groupId: 'g1', channelId: 'ch1', page: 2, pageSize: 10);
      expect(page2.events, hasLength(10));
      expect(page2.events.first.hlc, 1014);

      final page3 = await db.channelPage(groupId: 'g1', channelId: 'ch1', page: 3, pageSize: 10);
      expect(page3.events, hasLength(5));
      expect(page3.hasMore, isFalse);
    });

    test('channelPage without channelId returns group-level events', () async {
      await seedChannelEvents(groupId: 'g1', channelId: null, count: 5, baseHlc: 1000);
      await seedChannelEvents(groupId: 'g1', channelId: 'ch1', count: 5, baseHlc: 2000);

      final groupOnly = await db.channelPage(groupId: 'g1', channelId: null, page: 1, pageSize: 50);
      expect(groupOnly.events, hasLength(5));
      expect(groupOnly.events.every((e) => e.channelId == null), isTrue);
    });

    test('countEvents matches channelPage total', () async {
      await seedChannelEvents(groupId: 'g1', channelId: 'ch1', count: 37, baseHlc: 1000);

      final count = await db.countEvents('g1', channelId: 'ch1');
      expect(count, 37);
    });
  });
}
