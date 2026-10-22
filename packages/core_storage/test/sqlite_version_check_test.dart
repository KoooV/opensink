import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:core_storage/core_storage.dart';

/// Фейковый QueryExecutor, который делегирует вызовы к в-memory NativeDatabase,
/// но возвращает заведомо старую версию SQLite (3.23.0 < минимума 3.24.0)
/// для `SELECT sqlite_version()`.
class _FakeOldVersionExecutor implements QueryExecutor {
  final NativeDatabase _inner;

  _FakeOldVersionExecutor() : _inner = NativeDatabase.memory();

  @override
  SqlDialect get dialect => _inner.dialect;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    return _inner.ensureOpen(user);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
      String statement, List<Object?> args) async {
    if (statement.contains('sqlite_version')) {
      return [{'version': '3.23.0'}];
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
  Future<void> runCustom(String statement, [List<Object?>? args]) async {
    return _inner.runCustom(statement, args);
  }

  @override
  Future<void> runBatched(dynamic statements) async {
    return _inner.runBatched(statements);
  }

  @override
  TransactionExecutor beginTransaction() => _inner.beginTransaction();

  @override
  QueryExecutor beginExclusive() => _inner.beginExclusive();

  @override
  Future<void> close() => _inner.close();
}

void main() {
  group('SQLite version check at open', () {
    test('version below minimum → StorageOpenError.databaseVersionTooLow',
        () async {
      final executor = _FakeOldVersionExecutor();
      final db = AppDatabase(executor, version: 3);

      // Any public access triggers _ensureSchema → version check.
      try {
        await db.selectAllGroups();
        fail('Expected StorageOpenError.databaseVersionTooLow');
      } catch (e) {
        expect(e, isA<DatabaseVersionTooLow>());
        // sqlite_version() check should fail open before schema creation.
      } finally {
        await db.close();
        await executor.close();
      }
    });
  });
}
