import 'package:core_storage/core_storage.dart';
import 'package:drift/native.dart';

import 'drift_backend_types.dart';

/// VM-вариант: изолированная in-memory SQLite через native executor.
Future<DriftStoreHandle> openDriftStore(String name) async {
  final executor = NativeDatabase.memory();
  final db = AppDatabase(executor);
  await db.open(
    backend: 'memory',
    isPersistent: false,
    warnings: const ['core_sync e2e: in-memory database'],
  );
  return DriftStoreHandle(store: DriftEventStore(db), database: db);
}
