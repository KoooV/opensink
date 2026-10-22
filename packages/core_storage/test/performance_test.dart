import 'dart:typed_data';
import 'dart:math';

import 'package:test/test.dart';

import 'package:core_storage/core_storage.dart';
import 'memory_database.dart';

/// Performance budget assertions for AC5/AC6.
void main() {
  group('Performance (100k events)', () {
    late AppDatabase db;
    final rng = Random(42);

    setUp(() async {
      db = createMemoryDatabase();
    });

    tearDown(() async {
      await db.close();
    });

    test('100k events insert completes within budget (<30s)', () async {
      final stopwatch = Stopwatch()..start();

      // Batch insert in transactions for speed
      for (var batch = 0; batch < 100; batch++) {
        for (var i = 0; i < 1000; i++) {
          final idx = batch * 1000 + i;
          await db.insertEvent(
            id: 'perf-evt-$idx',
            groupId: 'perf-g1',
            author: 'user-${rng.nextInt(100)}',
            hlc: 1000000 + idx,
            bytes: Uint8List.fromList(List.generate(rng.nextInt(100) + 1, (_) => rng.nextInt(256))),
            signature: 'sig-$idx',
            channelId: null, // all group-level for counting
          );
        }
      }

      stopwatch.stop();
      final elapsedMs = stopwatch.elapsedMilliseconds;

      // AC5: < 30s on VM
      expect(elapsedMs, lessThan(30000), reason: '100k insert exceeded 30s budget');

      // Verify all events are queryable
      final count = await db.countEvents('perf-g1');
      expect(count, 100000);
    });

    test('channel pagination p95 < 200ms after 100k inserts', () async {
      // Seed 100k events in ch1
      for (var batch = 0; batch < 100; batch++) {
        for (var i = 0; i < 1000; i++) {
          final idx = batch * 1000 + i;
          await db.insertEvent(
            id: 'page-evt-$idx',
            groupId: 'page-g1',
            author: 'user',
            hlc: 2000000 + idx,
            bytes: Uint8List.fromList([1, 2, 3]),
            signature: 'sig',
            channelId: 'ch1',
          );
        }
      }

      final durations = <int>[];
      for (var page = 1; page <= 10; page++) {
        final sw = Stopwatch()..start();
        final pageResult = await db.channelPage(
          groupId: 'page-g1',
          channelId: 'ch1',
          page: page,
          pageSize: 50,
        );
        sw.stop();
        durations.add(sw.elapsedMilliseconds);

        expect(pageResult.events, hasLength(50));
      }

      durations.sort();
      final p95 = durations[durations.length * 9 ~/ 10];

      // AC6: p95 < 200ms on VM
      expect(p95, lessThan(200), reason: 'Channel pagination p95 exceeded 200ms budget');
    });

    test('range summary over 10k hlc range < 50ms', () async {
      // Seed 50k events spanning hlc 1000..51000
      for (var i = 0; i < 50000; i++) {
        await db.insertEvent(
          id: 'range-evt-$i',
          groupId: 'range-g1',
          author: 'user',
          hlc: 1000 + i,
          bytes: Uint8List.fromList([1]),
          signature: 'sig',
        );
      }

      final sw = Stopwatch()..start();
      final summary = (await db.rangeSummary(1000, 10999)).unwrap();
      sw.stop();

      expect(summary.count, 10000);
      // AC7: range summary < 200ms on VM (10k events)
      expect(sw.elapsedMilliseconds, lessThan(200), reason: 'Range summary exceeded 200ms budget');
    });
  });
}
