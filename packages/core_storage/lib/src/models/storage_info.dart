import 'package:drift/drift.dart';

/// Параметры открытия хранилища, задаваемые платформенным backend-ом.
class StorageSpec {
  /// Путь к файлу или имя базы данных; для memory игнорируется.
  final String name;

  /// Явно выбранное временное хранилище в памяти.
  final bool inMemory;

  const StorageSpec({required this.name, this.inMemory = false});
}

/// Сведения о реально открытом хранилище.
class StorageInfo {
  final String backend;
  final bool isPersistent;
  final String? sqliteVersion;
  final List<String> warnings;

  StorageInfo({
    required this.backend,
    required this.isPersistent,
    required this.sqliteVersion,
    List<String> warnings = const [],
  }) : warnings = List.unmodifiable(warnings);
}

/// Результат открытия платформенного хранилища.
class OpenedStorage {
  final QueryExecutor executor;
  final StorageInfo info;

  const OpenedStorage({required this.executor, required this.info});
}

/// Контракт открытия хранилища, реализуемый пакетами `platform_*`.
abstract interface class StorageBackend {
  Future<OpenedStorage> open(StorageSpec spec);
}

/// Типизированная ошибка открытия хранилища.
sealed class StorageOpenError implements Exception {
  const StorageOpenError();
}

class UnsupportedBackend extends StorageOpenError {
  final String backend;

  const UnsupportedBackend(this.backend);

  @override
  String toString() => 'Unsupported storage backend: $backend';
}

class DatabaseVersionTooLow extends StorageOpenError {
  final String required;
  final String actual;

  const DatabaseVersionTooLow(this.required, this.actual);

  @override
  String toString() =>
      'SQLite version $actual is lower than required version $required';
}

class ResourceMissing extends StorageOpenError {
  final String resource;

  const ResourceMissing(this.resource);

  @override
  String toString() => 'Storage resource is missing: $resource';
}

class OpenFailure extends StorageOpenError {
  final Object cause;
  final StackTrace? stack;

  const OpenFailure(this.cause, [this.stack]);

  @override
  String toString() => 'Storage open failed';
}
