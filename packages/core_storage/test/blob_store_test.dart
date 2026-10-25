import 'package:core_storage/core_storage.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  group('DriftBlobStore / schema v8', () {
    late AppDatabase db;
    late DriftBlobStore store;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await db.open(backend: 'memory', isPersistent: false);
      store = DriftBlobStore(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('schema v8 объявляет таблицу blob_transfers', () async {
      expect(schemaVersion, 8);
      expect(migrations.containsKey(8), isTrue);
      expect(allDdl.any((ddl) => ddl.contains('blob_transfers')), isTrue);
    });

    test('миграция v7 → v8 создаёт blob_transfers', () async {
      final executor = NativeDatabase.memory();
      await executor.ensureOpen(_SchemaV7User());
      for (final ddl in allDdl.where(
        (statement) => !statement.contains('blob_transfers'),
      )) {
        await executor.runCustom(ddl);
      }
      await executor.runInsert(
        'INSERT INTO schema_info (id, version) VALUES (1, 7)',
        const [],
      );

      final migrated = AppDatabase(executor);
      try {
        await migrated.open(backend: 'memory', isPersistent: false);
        expect(await migrated.receivedBlobChunks('missing'), isEmpty);
        final version = await executor.runSelect(
          'SELECT version FROM schema_info WHERE id = 1',
          const [],
        );
        expect(version.single['version'], 8);
      } finally {
        await migrated.close();
      }
    });

    test('чанки сохраняются, читаются и очищаются', () async {
      await store.writeChunk('file-a', 0, const <int>[1, 2, 3]);
      await store.writeChunk('file-a', 1, const <int>[4, 5]);
      await store.writeChunk('file-b', 0, const <int>[9]);

      expect(await store.receivedChunks('file-a'), <int>{0, 1});
      expect(await store.readChunk('file-a', 0), <int>[1, 2, 3]);
      expect(await store.readChunk('file-a', 1), <int>[4, 5]);
      expect(await store.readChunk('file-a', 2), isNull);
      expect(await store.totalBytes(), 6);

      await store.clear('file-a');

      expect(await store.receivedChunks('file-a'), isEmpty);
      expect(await store.readChunk('file-a', 0), isNull);
      expect(await store.totalBytes(), 1);
    });

    test(
      'повторная запись чанка заменяет данные и не дублирует объём',
      () async {
        await store.writeChunk('file', 0, const <int>[1, 2, 3]);
        await store.writeChunk('file', 0, const <int>[7]);

        expect(await store.readChunk('file', 0), <int>[7]);
        expect(await store.totalBytes(), 1);
        expect(await store.receivedChunks('file'), <int>{0});
      },
    );
  });
}

class _SchemaV7User implements QueryExecutorUser {
  @override
  int get schemaVersion => 7;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}
