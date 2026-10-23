import 'dart:io';

import 'package:core_domain/core_domain.dart';
import 'package:core_storage/core_storage.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

const _author =
    '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

EventRecord _record(int value) => EventRecord(
  id: 'same-id',
  groupId: const GroupId('group-1'),
  author: _author,
  payload: [value],
  timestamp: 100,
  signature: 'sig-$value',
);

void main() {
  group('EventStore concurrent idempotent writes', () {
    test('parallel writes in one transaction have one winner', () async {
      final executor = NativeDatabase.memory();
      final baseDb = AppDatabase(executor);
      await baseDb.selectAllGroups();

      final transaction = executor.beginTransaction();
      final transactionDb = AppDatabase(transaction);
      final store = DriftEventStore(transactionDb);
      try {
        final records = List.generate(12, _record);
        final results = await Future.wait(records.map(store.write));
        final insertedIndexes = <int>[];
        for (var i = 0; i < results.length; i++) {
          expect(results[i].isOk, isTrue);
          if (results[i].unwrap().inserted) insertedIndexes.add(i);
        }

        expect(insertedIndexes, hasLength(1));
        expect(
          results.where((result) => result.unwrap().duplicate),
          hasLength(11),
        );
        final saved = await store.getEvent('same-id');
        expect(saved?.payload, [insertedIndexes.single]);
        await transaction.send();
      } finally {
        await store.close();
        await baseDb.close();
      }
    });

    test(
      'parallel writes from separate transactions have one winner',
      () async {
        final directory = await Directory.systemTemp.createTemp('opensink-db-');
        final path = '${directory.path}/events.sqlite';
        final firstDb = AppDatabase(NativeDatabase(File(path)));
        final secondDb = AppDatabase(NativeDatabase(File(path)));
        final firstStore = DriftEventStore(firstDb);
        final secondStore = DriftEventStore(secondDb);
        try {
          await firstDb.selectAllGroups();
          await secondDb.selectAllGroups();
          final results = await Future.wait([
            firstStore.write(_record(1)),
            secondStore.write(_record(2)),
          ]);

          expect(
            results.where((result) => result.unwrap().inserted),
            hasLength(1),
          );
          expect(
            results.where((result) => result.unwrap().duplicate),
            hasLength(1),
          );
          final winnerIndex = results[0].unwrap().inserted ? 0 : 1;
          final saved = await firstStore.getEvent('same-id');
          expect(saved?.payload, [winnerIndex + 1]);
        } finally {
          await firstStore.close();
          await secondStore.close();
          await directory.delete(recursive: true);
        }
      },
    );
  });
}
