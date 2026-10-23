import 'package:core_storage/core_storage.dart';
import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:platform_web/platform_web.dart';
// ignore: experimental_member_use
import 'package:sqlite3/wasm.dart';

import '../../core_storage/test/portable_storage_suite.dart';

Uri _asset(String name) => Uri.base
    .resolve('../.dart_tool/storage_test_web_assets/')
    .resolve(name);

final _factory = WebDatabaseFactory(
  sqlite3Uri: _asset('sqlite3.wasm'),
  driftWorkerUri: _asset('drift_worker.js'),
);

Future<OpenedStorage> _openStorage() =>
    _factory.open(const StorageSpec(name: 'portable-memory', inMemory: true));

Future<QueryExecutor> _openRawExecutor() async {
  final sqlite3 = await WasmSqlite3.loadFromUrl(_asset('sqlite3.wasm'));
  sqlite3.registerVirtualFileSystem(InMemoryFileSystem(), makeDefault: true);
  return WasmDatabase.inMemory(sqlite3);
}

void main() {
  runPortableStorageSuite(
    'Chrome WASM',
    openStorage: _openStorage,
    openRawExecutor: _openRawExecutor,
  );
}
