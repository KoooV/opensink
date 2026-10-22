import 'dart:typed_data';

import 'package:core_storage/core_storage.dart';
import 'package:platform_web/platform_web.dart';
import 'package:test/test.dart';

void main() {
  test(
    '100k WASM event inserts and paginated reads meet layer 4 budgets',
    () async {
      final assetDirectory =
          Uri.base.resolve('../.dart_tool/storage_test_web_assets/');
      final opened = await WebDatabaseFactory(
        sqlite3Uri: assetDirectory.resolve('sqlite3.wasm'),
        driftWorkerUri: assetDirectory.resolve('drift_worker.js'),
      ).open(
        const StorageSpec(name: 'web-performance', inMemory: true),
      );
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
              'web-perf-$index',
              'web-performance-group',
              '01' * 32,
              index,
              Uint8List.fromList(const [1, 2, 3]),
              'signature',
              'web-performance-channel',
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
          groupId: 'web-performance-group',
          channelId: 'web-performance-channel',
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
        'WEB_STORAGE_PERF events=$eventCount '
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
