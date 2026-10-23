import 'package:core_storage/core_storage.dart';
import 'package:platform_web/platform_web.dart';

import '../../core_storage/test/portable_performance_suite.dart';

Uri _asset(String name) => Uri.base
    .resolve('../.dart_tool/storage_test_web_assets/')
    .resolve(name);

Future<OpenedStorage> _openStorage() => WebDatabaseFactory(
  sqlite3Uri: _asset('sqlite3.wasm'),
  driftWorkerUri: _asset('drift_worker.js'),
).open(const StorageSpec(name: 'web-performance', inMemory: true));

void main() {
  runPortablePerformanceSuite(
    'Chrome WASM',
    openStorage: _openStorage,
    reportPrefix: 'WEB_STORAGE_PERF',
  );
}
