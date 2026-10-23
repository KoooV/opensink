import 'package:core_storage/core_storage.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'schema_v3_snapshot.dart';
import 'schema_v5_snapshot.dart';

class _OldVersionExecutor implements QueryExecutor {
  final NativeDatabase _inner = NativeDatabase.memory();

  @override
  SqlDialect get dialect => _inner.dialect;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) => _inner.ensureOpen(user);

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) {
    if (statement.toLowerCase().contains('sqlite_version')) {
      return Future.value([
        {'version': '3.23.0'},
      ]);
    }
    return _inner.runSelect(statement, args);
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _inner.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _inner.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      _inner.runDelete(statement, args);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _inner.runCustom(statement, args);

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _inner.runBatched(statements);

  @override
  TransactionExecutor beginTransaction() => _inner.beginTransaction();

  @override
  QueryExecutor beginExclusive() => _inner.beginExclusive();

  @override
  Future<void> close() => _inner.close();
}

class _SchemaV3ExecutorUser implements QueryExecutorUser {
  @override
  int get schemaVersion => 3;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

void main() {
  group('SQLite open validation and schema v6 migration', () {
    test('open returns SQLite version in StorageInfo', () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final info = await db.open(backend: 'memory', isPersistent: false);

        expect(info.backend, 'memory');
        expect(info.isPersistent, isFalse);
        expect(info.sqliteVersion, isA<String>());
      } finally {
        await db.close();
      }
    });

    test('SQLite below 3.24.0 fails with typed version error', () async {
      final executor = _OldVersionExecutor();
      final db = AppDatabase(executor);
      try {
        await expectLater(
          db.open(backend: 'memory', isPersistent: false),
          throwsA(
            isA<DatabaseVersionTooLow>()
                .having((error) => error.required, 'required', '3.24.0')
                .having((error) => error.actual, 'actual', '3.23.0'),
          ),
        );
      } finally {
        await db.close();
      }
    });

    test('schema version is raised to 4 and migration is declared', () {
      expect(schemaVersion, 6);
      expect(migrations.containsKey(6), isTrue);
    });

    test('v3 migration preserves known and quarantined authors', () async {
      final executor = NativeDatabase.memory();
      await executor.ensureOpen(_SchemaV3ExecutorUser());
      for (final statement in schemaV3Snapshot) {
        await executor.runCustom(statement);
      }
      await executor.runInsert(
        'INSERT INTO schema_info (id, version) VALUES (1, 3)',
        const [],
      );
      await executor.runInsert(
        'INSERT INTO events (id, group_id, author, hlc, bytes, signature) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          'known-author',
          'group-1',
          '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
          100,
          Uint8List.fromList([1]),
          'sig-a',
        ],
      );
      await executor.runInsert(
        'INSERT INTO events (id, group_id, author, hlc, bytes, signature) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          'quarantined-author',
          'group-1',
          '',
          200,
          Uint8List.fromList([2]),
          'sig-b',
        ],
      );

      final newDb = AppDatabase(executor);
      try {
        final known = await newDb.getEventById('known-author');
        final quarantined = await newDb.getEventById('quarantined-author');

        expect(known?.author, startsWith('001122'));
        expect(quarantined, isNotNull);
        expect(quarantined!.author, isEmpty);
        expect(quarantined.bytes, [2]);
        final versionRows = await executor.runSelect(
          'SELECT version FROM schema_info WHERE id = 1',
          const [],
        );
        expect(versionRows.single['version'], 6);
        final columns = await executor.runSelect(
          'PRAGMA table_info(events)',
          const [],
        );
        expect(columns.map((column) => column['name']), isNot(contains('seq')));

        await expectLater(
          executor.runUpdate(
            "UPDATE events SET signature = 'changed' WHERE id = ?",
            ['known-author'],
          ),
          throwsA(anything),
        );
        await expectLater(
          executor.runDelete(
            'DELETE FROM events WHERE id = ?',
            ['known-author'],
          ),
          throwsA(anything),
        );
      } finally {
        await newDb.close();
      }
    });

    test('v5 to v6 drops seq and preserves event data', () async {
      final executor = NativeDatabase.memory();
      await executor.ensureOpen(_SchemaV3ExecutorUser());
      for (final statement in schemaV5Snapshot) {
        await executor.runCustom(statement);
      }
      await executor.runInsert(
        'INSERT INTO schema_info (id, version) VALUES (1, 5)',
        const [],
      );
      await executor.runInsert(
        'INSERT INTO events '
        '(id, group_id, author, hlc, bytes, signature, channel_id, seq) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          'v5-event',
          'group-1',
          '00112233445566778899aabbccddeeff'
              '00112233445566778899aabbccddeeff',
          100,
          Uint8List.fromList([1, 2, 3]),
          'sig-v5',
          'channel-1',
          42,
        ],
      );

      final db = AppDatabase(executor);
      try {
        final event = await db.getEventById('v5-event');
        expect(event, isNotNull);
        expect(event!.groupId, 'group-1');
        expect(event.channelId, 'channel-1');
        expect(event.bytes, [1, 2, 3]);
        expect(event.signature, 'sig-v5');

        final columns = await executor.runSelect(
          'PRAGMA table_info(events)',
          const [],
        );
        expect(columns.map((column) => column['name']), isNot(contains('seq')));

        await expectLater(
          executor.runDelete(
            'DELETE FROM events WHERE id = ?',
            ['v5-event'],
          ),
          throwsA(anything),
        );
      } finally {
        await db.close();
      }
    });

    test('fresh install has append-only triggers', () async {
      final executor = NativeDatabase.memory();
      final db = AppDatabase(executor);
      try {
        await db.open(backend: 'memory', isPersistent: false);
        await db.insertEvent(
          id: 'trigger-event',
          groupId: 'group-1',
          author: '00112233445566778899aabbccddeeff'
              '00112233445566778899aabbccddeeff',
          hlc: 100,
          bytes: [1],
          signature: 'sig',
        );

        await expectLater(
          executor.runUpdate(
            "UPDATE events SET signature = 'changed' WHERE id = ?",
            ['trigger-event'],
          ),
          throwsA(anything),
        );
        await expectLater(
          executor.runDelete(
            'DELETE FROM events WHERE id = ?',
            ['trigger-event'],
          ),
          throwsA(anything),
        );
        expect(await db.getEventById('trigger-event'), isNotNull);
      } finally {
        await db.close();
      }
    });
  });
}
