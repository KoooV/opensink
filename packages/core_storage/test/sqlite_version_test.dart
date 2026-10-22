import 'package:drift/native.dart';
import 'package:drift/drift.dart';
import 'package:test/test.dart';

/// Stub [QueryExecutorUser] used only to open a raw executor for this check.
class _StubQueryExecutorUser implements QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(QueryExecutor ex, OpeningDetails d) async {}
}

/// Проверка remark 3: `ON CONFLICT(id) DO UPDATE` требует SQLite >= 3.24.0.
/// Утверждаем, что доступная (bundled / системная) SQLite удовлетворяет этому.
void main() {
  group('SQLite version (remark 3)', () {
    test('bundled sqlite supports ON CONFLICT upsert (version >= 3.24.0)', () async {
      final executor = NativeDatabase.memory();

      await executor.ensureOpen(_StubQueryExecutorUser());
      try {
        final rows = await executor.runSelect('SELECT sqlite_version() as v', []);
        final version = rows.first['v'] as String;
        final parts = version.split('.').map(int.parse).toList();

        // ON CONFLICT upsert landed in SQLite 3.24.0.
        expect(parts[0], greaterThanOrEqualTo(3),
            reason: 'unexpected SQLite major version: $version');
        if (parts[0] == 3) {
          expect(parts[1], greaterThanOrEqualTo(24),
              reason: 'SQLite $version predates ON CONFLICT upsert (3.24.0)');
        }

        // Прямая проверка: ON CONFLICT(id) DO UPDATE выполняется без ошибки.
        // Сначала вставляем строку, затем upsert по тому же id должен обновить её.
        await executor.runCustom('''
CREATE TABLE IF NOT EXISTS _version_check (
  id TEXT NOT NULL PRIMARY KEY,
  value INTEGER NOT NULL
)
''');
        await executor.runInsert(
          'INSERT INTO _version_check (id, value) VALUES (?, ?)',
          ['v1', 1],
        );
        await executor.runInsert(
          'INSERT INTO _version_check (id, value) VALUES (?, ?) '
          'ON CONFLICT(id) DO UPDATE SET value = ?',
          ['v1', 9, 2],
        );
        final check = await executor.runSelect(
          'SELECT value FROM _version_check WHERE id = ?',
          ['v1'],
        );
        expect(check.first['value'], 2);
      } finally {
        await executor.close();
      }
    });
  });
}
