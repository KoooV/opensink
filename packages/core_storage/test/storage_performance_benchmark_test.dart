import 'dart:typed_data';

import 'package:core_storage/core_storage.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  test(
    '100k native events insert and paginated reads meet layer 4 budgets',
    () async {
      final executor = NativeDatabase.memory();
      final database = AppDatabase(executor);
      await database.open(backend: 'memory', isPersistent: false);
      final insertWatch = Stopwatch()..start();
      const eventCount = 100000;
      final transaction = executor.beginTransaction();
      try {
        await transaction.ensureOpen(database);
        for (var index = 0; index < eventCount; index++) {
          await transaction.runUpdate(
            'INSERT INTO events '
            '(id, group_id, author, hlc, bytes, signature, channel_id) '
            'VALUES (?, ?, ?, ?, ?, ?, ?)',
            [
              'vm-perf-$index',
              'vm-performance-group',
              '01' * 32,
              index,
              Uint8List.fromList(const [1, 2, 3]),
              'signature',
              'vm-performance-channel',
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
          groupId: 'vm-performance-group',
          channelId: 'vm-performance-channel',
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
        'VM_STORAGE_PERF events=$eventCount '
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
