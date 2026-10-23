import 'package:core_storage/core_storage.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'portable_storage_suite.dart';

Future<OpenedStorage> _openStorage() async {
  final executor = NativeDatabase.memory();
  final info = await AppDatabase(executor).open(
    backend: 'memory',
    isPersistent: false,
    warnings: const ['memory'],
  );
  return OpenedStorage(executor: executor, info: info);
}

Future<QueryExecutor> _openRawExecutor() async => NativeDatabase.memory();

void main() {
  runPortableStorageSuite(
    'native VM',
    openStorage: _openStorage,
    openRawExecutor: _openRawExecutor,
  );
}
