import 'package:core_domain/core_domain.dart';
import 'package:core_storage/core_storage.dart';
import 'package:test/test.dart';

/// Запускает общий контракт EventStore на указанном платформенном backend-е.
void runEventStoreContract(
  String backendName,
  Future<OpenedStorage> Function() openStorage, {
  required bool persistent,
}) {
  group('EventStore contract ($backendName)', () {
    test('writes, reads and does not replace a duplicate event', () async {
      final opened = await openStorage();
      final database = AppDatabase(opened.executor);
      final store = DriftEventStore(database);
      final original = EventRecord(
        id: 'contract-event',
        groupId: const GroupId('contract-group'),
        author: List.filled(32, '01').join(),
        payload: const [1, 2, 3],
        timestamp: 1234,
        signature: 'signature',
      );
      final duplicate = EventRecord(
        id: original.id,
        groupId: original.groupId,
        author: original.author,
        payload: const [9, 8, 7],
        timestamp: 5678,
        signature: 'other-signature',
      );

      try {
        expect(opened.info.backend, persistent ? 'file' : 'memory');
        expect(opened.info.isPersistent, persistent);
        expect(opened.info.sqliteVersion, isNotEmpty);

        final inserted = await store.write(original);
        expect(inserted, isA<Ok<InsertOutcome, EventStoreWriteError>>());
        expect(inserted.unwrap().inserted, isTrue);

        final repeated = await store.write(duplicate);
        expect(repeated.unwrap().duplicate, isTrue);

        final readBack = await store.getEvent(original.id);
        expect(readBack?.author, original.author);
        expect(readBack?.payload, original.payload);
        expect(readBack?.timestamp, original.timestamp);
        expect(readBack?.signature, original.signature);
        if (!persistent) {
          expect(opened.info.warnings, isNotEmpty);
        }
      } finally {
        await store.close();
      }
    });
  });
}
