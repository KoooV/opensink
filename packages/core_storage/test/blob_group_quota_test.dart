import 'package:core_storage/core_storage.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  group('DriftBlobStore / per-group quota', () {
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

    test('schema v9 persists group attribution per chunk', () async {
      expect(schemaVersion, 9);
      await store.writeChunk('file-a', 0, const <int>[
        1,
        2,
        3,
      ], groupId: 'group-a');
      await store.writeChunk('file-b', 0, const <int>[
        4,
        5,
      ], groupId: 'group-b');
      await store.writeChunk('file-b', 1, const <int>[6], groupId: 'group-b');

      expect(await store.totalBytesForGroup('group-a'), 3);
      expect(await store.totalBytesForGroup('group-b'), 3);
      expect(await store.totalBytesForGroup('missing'), 0);
      expect(await store.totalBytes(), 6);

      await store.clear('file-a');
      expect(await store.totalBytesForGroup('group-a'), 0);
      expect(await store.totalBytesForGroup('group-b'), 3);
    });

    test('migration v8 → v9 adds group_id with empty default', () async {
      final executor = NativeDatabase.memory();
      await executor.ensureOpen(_SchemaV8User());
      await executor.runCustom('''
CREATE TABLE blob_transfers (
  file_id TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  bytes BLOB NOT NULL,
  received_at INTEGER NOT NULL,
  PRIMARY KEY (file_id, chunk_index)
)
''');
      await executor.runCustom('''
CREATE TABLE schema_info (
  id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
  version INTEGER NOT NULL
)
''');
      await executor.runInsert(
        'INSERT INTO schema_info (id, version) VALUES (1, 8)',
        const [],
      );
      await executor.runInsert(
        'INSERT INTO blob_transfers (file_id, chunk_index, bytes, received_at) '
        'VALUES (?, ?, ?, ?)',
        [
          'legacy',
          0,
          Uint8List.fromList(const <int>[1, 2]),
          1,
        ],
      );

      final migrated = AppDatabase(executor);
      try {
        await migrated.open(backend: 'memory', isPersistent: false);
        final migratedStore = DriftBlobStore(migrated);
        expect(await migratedStore.totalBytes(), 2);
        expect(await migratedStore.totalBytesForGroup(''), 2);
        final version = await executor.runSelect(
          'SELECT version FROM schema_info WHERE id = 1',
          const [],
        );
        expect(version.single['version'], 9);
      } finally {
        await migrated.close();
      }
    });
  });
}

class _SchemaV8User implements QueryExecutorUser {
  @override
  int get schemaVersion => 8;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}
