import 'package:core_storage/core_storage.dart';

/// Открытое Drift-хранилище для e2e-тестов core_sync.
///
/// [close] закрывает и store, и нижележащую БД.
class DriftStoreHandle {
  DriftStoreHandle({required this.store, required this.database});

  final DriftEventStore store;
  final AppDatabase database;

  Future<void> close() => store.close();
}
