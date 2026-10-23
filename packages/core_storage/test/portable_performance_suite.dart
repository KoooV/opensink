import 'dart:typed_data';

import 'package:core_storage/core_storage.dart';
import 'package:test/test.dart';

/// Общий замер 100k событий: один и тот же код на VM и в Chrome.
void runPortablePerformanceSuite(
  String backendName, {
  required Future<OpenedStorage> Function() openStorage,
  required String reportPrefix,
}) {
  test(
    '100k events insert and paginated reads ($backendName)',
    () async {
      final opened = await openStorage();
      final database = AppDatabase(opened.executor);
      await database.open(backend: 'memory', isPersistent: false);

      final insertWatch = Stopwatch()..start();
      const eventCount = 100000;
      final transaction = opened.executor.beginTransaction();
      try {
        await transaction.ensureOpen(database);
        for (var index = 0; index < eventCount; index++) {
          await transaction.runUpdate(
            'INSERT INTO events '
            '(id, group_id, author, hlc, bytes, signature, channel_id) '
            'VALUES (?, ?, ?, ?, ?, ?, ?)',
            [
              'perf-$index',
              'performance-group',
              '01' * 32,
              index,
              Uint8List.fromList(const [1, 2, 3]),
              'signature',
              'performance-channel',
            ],
          );
        }
        await transaction.send();
      } on Object {
        await transaction.rollback();
        rethrow;
      }
      insertWatch.stop();

      final paginationDurations = <int>[];
      for (var page = 1; page <= 10; page++) {
        final watch = Stopwatch()..start();
        final result = await database.channelPage(
          groupId: 'performance-group',
          channelId: 'performance-channel',
          page: page,
          pageSize: 50,
        );
        watch.stop();
        expect(result.events, hasLength(50));
        paginationDurations.add(watch.elapsedMilliseconds);
      }
      paginationDurations.sort();
      final p95 = paginationDurations[9];

      // ignore: avoid_print
      print(
        '$reportPrefix events=$eventCount '
        'insert_ms=${insertWatch.elapsedMilliseconds} '
        'pagination_p95_ms=$p95',
      );
      expect(insertWatch.elapsed, lessThan(const Duration(seconds: 30)));
      expect(p95, lessThan(200));
      await database.close();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
