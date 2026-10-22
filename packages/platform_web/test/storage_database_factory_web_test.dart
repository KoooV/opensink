import 'package:core_domain/core_domain.dart';
import 'package:core_storage/core_storage.dart';
import 'package:platform_web/platform_web.dart';
import 'package:test/test.dart';

import '../../core_storage/test/event_store_contract.dart';

void main() {
  final assetDirectory =
      Uri.base.resolve('../.dart_tool/storage_test_web_assets/');
  final factory = WebDatabaseFactory(
    sqlite3Uri: assetDirectory.resolve('sqlite3.wasm'),
    driftWorkerUri: assetDirectory.resolve('drift_worker.js'),
  );

  runEventStoreContract(
    'WASM in-memory',
    () => factory.open(
      const StorageSpec(name: 'contract-memory', inMemory: true),
    ),
    persistent: false,
  );

  group('WebDatabaseFactory', () {
    test('reports the selected persistent implementation', () async {
      final opened = await factory.open(
        StorageSpec(
          name: 'storage-info-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      try {
        expect(opened.info.backend, anyOf('opfs', 'indexedDb', 'memory'));
        expect(opened.info.isPersistent, opened.info.backend != 'memory');
        expect(opened.info.sqliteVersion, isNotEmpty);
        if (!opened.info.isPersistent || opened.info.backend == 'indexedDb') {
          expect(opened.info.warnings, isNotEmpty);
        }
      } finally {
        await opened.executor.close();
      }
    });

    test('persistent data survives opening a new database instance', () async {
      final databaseName =
          'persistence-${DateTime.now().microsecondsSinceEpoch}';
      final first = await factory.open(StorageSpec(name: databaseName));
      expect(first.info.isPersistent, isTrue);
      final firstStore = DriftEventStore(AppDatabase(first.executor));
      final event = EventRecord(
        id: 'persistent-web-event',
        groupId: const GroupId('persistent-web-group'),
        author: List.filled(32, '01').join(),
        payload: const [4, 5, 6],
        timestamp: 12345,
        signature: 'signature',
      );
      try {
        expect((await firstStore.write(event)).unwrap().inserted, isTrue);
      } finally {
        await firstStore.close();
      }

      final second = await factory.open(StorageSpec(name: databaseName));
      final secondStore = DriftEventStore(AppDatabase(second.executor));
      try {
        final restored = await secondStore.getEvent(event.id);
        expect(restored?.payload, event.payload);
        expect(restored?.author, event.author);
      } finally {
        await secondStore.close();
      }
    });

    test('reports a missing sqlite3.wasm as a typed resource error', () async {
      final missingResourceFactory = WebDatabaseFactory(
        sqlite3Uri: assetDirectory.resolve('missing-sqlite3.wasm'),
      );
      await expectLater(
        missingResourceFactory.open(const StorageSpec(name: 'missing-wasm')),
        throwsA(
          isA<ResourceMissing>().having(
            (error) => error.resource,
            'resource',
            contains('sqlite3.wasm'),
          ),
        ),
      );
    });

    test('reports a missing drift worker as a typed resource error', () async {
      final missingResourceFactory = WebDatabaseFactory(
        sqlite3Uri: assetDirectory.resolve('sqlite3.wasm'),
        driftWorkerUri: assetDirectory.resolve('missing-drift-worker.js'),
      );
      await expectLater(
        missingResourceFactory.open(const StorageSpec(name: 'missing-worker')),
        throwsA(
          isA<ResourceMissing>().having(
            (error) => error.resource,
            'resource',
            contains('drift_worker.js'),
          ),
        ),
      );
    });
  });
}
