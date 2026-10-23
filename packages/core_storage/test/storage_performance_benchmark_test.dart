import 'package:core_storage/core_storage.dart';
import 'package:drift/native.dart';

import 'portable_performance_suite.dart';

Future<OpenedStorage> _openStorage() async {
  final executor = NativeDatabase.memory();
  final info = await AppDatabase(executor).open(
    backend: 'memory',
    isPersistent: false,
    warnings: const ['memory'],
  );
  return OpenedStorage(executor: executor, info: info);
}

void main() {
  runPortablePerformanceSuite(
    'native VM',
    openStorage: _openStorage,
    reportPrefix: 'VM_STORAGE_PERF',
  );
}
