import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:core_domain/core_domain.dart';
import 'package:core_storage/core_storage.dart';
import 'memory_database.dart';
void main() {
  group('SyncQueries (range summary + batch)', () {
    late AppDatabase db;

    setUp(() {
      db = createMemoryDatabase();
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> seedEvents(int count, {int baseHlc = 1000, String groupId = 'g1', String idPrefix = 'evt'}) async {
      for (var i = 0; i < count; i++) {
        await db.insertEvent(
          id: '$idPrefix-$groupId-$i',
          groupId: groupId,
          author: 'user-$i',
          hlc: baseHlc + i,
          bytes: Uint8List.fromList(List.filled(10, i)),
          signature: 'sig-$i',
        );
      }
    }

    test('rangeSummary returns count and hash', () async {
      await seedEvents(50);

      final summary = (await db.rangeSummary(1000, 1049)).unwrap();
      expect(summary.count, 50);
      expect(summary.hlcFrom, 1000);
      expect(summary.hlcTo, 1049);
      expect(summary.rangeHash, hasLength(32));
      expect(summary.rangeHashHex, hasLength(64));
    });

    test('rangeSummary empty range returns count 0', () async {
      await seedEvents(10);

      final summary = (await db.rangeSummary(9000, 9999)).unwrap();
      expect(summary.count, 0);
      expect(summary.rangeHash, hasLength(32));
      expect(
        summary.rangeHashHex,
        'e3b0c44298fc1c149afbf4c8996fb924'
        '27ae41e4649b934ca495991b7852b855',
      );
    });

    test('rangeSummary returns typed error instead of truncating', () async {
      await seedEvents(5);

      final result = await db.rangeSummary(1000, 1004, limit: 4);
      expect(result, isA<Err<RangeSummary, RangeSummaryError>>());
      expect(result.unwrapErr(), isA<RangeTooLarge>());
      expect((result.unwrapErr() as RangeTooLarge).limit, 4);
    });

    test('batchEvents returns events in hlc order with limit/offset', () async {
      await seedEvents(100);

      final batch = await db.batchEvents(hlcFrom: 1000, hlcTo: 1099, limit: 10, offset: 0);
      expect(batch, hasLength(10));
      expect(batch.first.id, 'evt-g1-0');
      expect(batch.last.id, 'evt-g1-9');

      final batch2 = await db.batchEvents(hlcFrom: 1000, hlcTo: 1099, limit: 10, offset: 10);
      expect(batch2.first.id, 'evt-g1-10');
    });

    test('groupEvents returns all events for a group', () async {
      await seedEvents(5, groupId: 'g1', idPrefix: 'g1evt');
      await seedEvents(3, groupId: 'g2', idPrefix: 'g2evt');

      final g1 = await db.groupEvents('g1');
      expect(g1, hasLength(5));

      final g2 = await db.groupEvents('g2');
      expect(g2, hasLength(3));

      final g1limited = await db.groupEvents('g1', limit: 2);
      expect(g1limited, hasLength(2));
    });

    test('getEventById returns EventData or null', () async {
      await seedEvents(3);

      final found = await db.getEventById('evt-g1-1');
      expect(found, isNotNull);
      expect(found!.id, 'evt-g1-1');
      expect(found.hlc, 1001);

      final missing = await db.getEventById('missing');
      expect(missing, isNull);
    });
  });
}
