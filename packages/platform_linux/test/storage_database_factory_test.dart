import 'dart:io';

import 'package:core_domain/core_domain.dart';
import 'package:core_storage/core_storage.dart';
import 'package:platform_linux/src/storage_database_factory.dart';
import 'package:test/test.dart';

import '../../core_storage/test/event_store_contract.dart';

void main() {
  late Directory testDirectory;
  late LinuxDatabaseFactory backend;

  setUpAll(() async {
    testDirectory = await Directory.systemTemp.createTemp('opensink_storage_');
    backend = LinuxDatabaseFactory(
      supportDirectoryProvider: () async => testDirectory,
    );
  });

  tearDownAll(() async {
    if (await testDirectory.exists()) {
      await testDirectory.delete(recursive: true);
    }
  });

  runEventStoreContract(
    'in-memory Linux database',
    () => backend.open(const StorageSpec(name: 'ignored.db', inMemory: true)),
    persistent: false,
  );

  runEventStoreContract(
    'temporary Linux database file',
    () => backend.open(const StorageSpec(name: 'contract.db')),
    persistent: true,
  );

  test('reopening the same file preserves event data', () async {
    final first = await backend.open(const StorageSpec(name: 'restart.db'));
    final firstStore = DriftEventStore(AppDatabase(first.executor));
    final record = EventRecord(
      id: 'restart-event',
      groupId: const GroupId('restart-group'),
      author: List.filled(32, 'ab').join(),
      payload: const [3, 1, 4, 1, 5],
      timestamp: 7890,
      signature: 'restart-signature',
    );

    final writeResult = await firstStore.write(record);
    expect(writeResult.unwrap().inserted, isTrue);
    await firstStore.close();

    final second = await backend.open(const StorageSpec(name: 'restart.db'));
    final secondStore = DriftEventStore(AppDatabase(second.executor));
    try {
      final stored = await secondStore.getEvent(record.id);
      expect(stored?.author, record.author);
      expect(stored?.payload, record.payload);
      expect(second.info.backend, 'file');
      expect(second.info.isPersistent, isTrue);
      expect(second.info.sqliteVersion, isNotEmpty);
    } finally {
      await secondStore.close();
    }
  });

  test('file database applies the configured SQLite pragmas', () async {
    final opened = await backend.open(const StorageSpec(name: 'pragmas.db'));
    try {
      final foreignKeys = await opened.executor.runSelect(
        'PRAGMA foreign_keys',
        const [],
      );
      final journalMode = await opened.executor.runSelect(
        'PRAGMA journal_mode',
        const [],
      );
      final synchronous = await opened.executor.runSelect(
        'PRAGMA synchronous',
        const [],
      );

      expect(foreignKeys.single.values.single, 1);
      expect(journalMode.single.values.single.toString().toLowerCase(), 'wal');
      expect(synchronous.single.values.single, 2);
    } finally {
      await opened.executor.close();
    }
  });

  test(
    'file in a temporary directory includes a persistence warning',
    () async {
      final opened = await backend.open(const StorageSpec(name: 'warning.db'));
      try {
        expect(opened.info.backend, 'file');
        expect(opened.info.isPersistent, isTrue);
        expect(
          opened.info.warnings,
          contains(
            'Файл БД находится во временном каталоге и может быть удалён ОС.',
          ),
        );
      } finally {
        await opened.executor.close();
      }
    },
  );

  test('corrupted database returns a typed Result error', () async {
    await File('${testDirectory.path}${Platform.pathSeparator}corrupt.db')
        .writeAsString('not a sqlite database');

    final result = await backend.openResult(
      const StorageSpec(name: 'corrupt.db'),
    );

    expect(result, isA<Err<OpenedStorage, StorageOpenError>>());
    expect(result.unwrapErr(), isA<OpenFailure>());
  });

  test('unavailable storage directory returns a typed Result error', () async {
    final unavailableBackend = LinuxDatabaseFactory(
      supportDirectoryProvider: () async {
        throw const FileSystemException('permission denied');
      },
    );

    final result = await unavailableBackend.openResult(
      const StorageSpec(name: 'unavailable.db'),
    );

    expect(result, isA<Err<OpenedStorage, StorageOpenError>>());
    expect(result.unwrapErr(), isA<OpenFailure>());
  });
}
