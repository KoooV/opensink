import 'package:core_storage/core_storage.dart';
import 'package:platform_web/platform_web.dart';

import 'drift_backend_types.dart';

Uri _asset(String name) =>
    Uri.base.resolve('../.dart_tool/sync_test_web_assets/').resolve(name);

/// Chrome-вариант: SQLite WASM с теми же закреплёнными ресурсами, что и
/// platform_web. Ресурсы подготавливает tool/test_web_sync_chrome.sh.
Future<DriftStoreHandle> openDriftStore(String name) async {
  final opened = await WebDatabaseFactory(
    sqlite3Uri: _asset('sqlite3.wasm'),
    driftWorkerUri: _asset('drift_worker.js'),
  ).open(StorageSpec(name: name, inMemory: true));
  final db = AppDatabase(opened.executor);
  await db.open(
    backend: opened.info.backend,
    isPersistent: false,
    warnings: opened.info.warnings,
  );
  return DriftStoreHandle(store: DriftEventStore(db), database: db);
}
