import 'dart:io';

import 'package:core_storage/core_storage.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Фабрика SQLite для Android.
///
/// Постоянная БД создаётся в application support directory. Для файловой БД
/// используется SQLite, поставляемая `sqlite3_flutter_libs`; системная SQLite
/// устройства не является источником версии.
class AndroidDatabaseFactory implements StorageBackend {
  final Future<Directory> Function() _supportDirectoryProvider;

  AndroidDatabaseFactory({
    Future<Directory> Function()? supportDirectoryProvider,
  }) : _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  @override
  Future<OpenedStorage> open(StorageSpec spec) async {
    QueryExecutor? executor;
    try {
      if (spec.inMemory) {
        executor = NativeDatabase.memory(setup: _configureSqlite);
        final info = await AppDatabase(executor).open(
          backend: 'memory',
          isPersistent: false,
          warnings: const [
            'Режим памяти: данные не сохраняются после закрытия.',
          ],
        );
        return OpenedStorage(executor: executor, info: info);
      }

      _validateName(spec.name);
      final supportDirectory = await _supportDirectoryProvider();
      await supportDirectory.create(recursive: true);
      final file = File(
        '${supportDirectory.path}${Platform.pathSeparator}${spec.name}',
      );
      executor = NativeDatabase.createInBackground(
        file,
        setup: _configureSqlite,
      );
      final warnings = await _temporaryDirectoryWarning(file);
      final info = await AppDatabase(executor)
          .open(backend: 'file', isPersistent: true, warnings: warnings);
      return OpenedStorage(executor: executor, info: info);
    } on StorageOpenError {
      await _closeOnFailure(executor);
      rethrow;
    } catch (error, stack) {
      await _closeOnFailure(executor);
      throw OpenFailure(error, stack);
    }
  }

  static void _configureSqlite(Database database) {
    database.execute('PRAGMA foreign_keys = ON');
    database.execute('PRAGMA journal_mode = WAL');
    database.execute('PRAGMA synchronous = FULL');
  }

  static void _validateName(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(String.fromCharCode(92))) {
      throw OpenFailure(
        ArgumentError.value(name, 'name', 'Ожидалось имя файла БД'),
      );
    }
  }

  static Future<List<String>> _temporaryDirectoryWarning(File file) async {
    final fileDirectory = await file.parent.resolveSymbolicLinks();
    final temporaryDirectory = await Directory.systemTemp
        .resolveSymbolicLinks();
    final temporaryPrefix = '$temporaryDirectory${Platform.pathSeparator}';
    if (fileDirectory == temporaryDirectory ||
        fileDirectory.startsWith(temporaryPrefix)) {
      return const [
        'Файл БД находится во временном каталоге и может быть удалён ОС.',
      ];
    }
    return const [];
  }

  static Future<void> _closeOnFailure(QueryExecutor? executor) async {
    if (executor == null) return;
    try {
      await executor.close();
    } on Object catch (_) {
      // Сохраняем исходную типизированную ошибку открытия.
    }
  }
}
