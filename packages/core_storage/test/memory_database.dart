library;

/// In-memory database factory for core_storage tests.
///
/// Lives in `test/` (not `lib/`) so it may import `package:drift/native.dart`,
/// which is forbidden in `core_storage` production code (see
/// platform factory via `StorageBackend`). Platform-agnostic callers receive a
/// `QueryExecutor` and pass it to `AppDatabase`.

import 'package:drift/native.dart';

import 'package:core_storage/core_storage.dart';

/// Creates an in-memory [AppDatabase] for tests.
AppDatabase createMemoryDatabase() {
  final executor = NativeDatabase.memory();
  return AppDatabase(executor);
}
