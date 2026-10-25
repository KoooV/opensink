library;

/// Слой хранения OpenSink на базе drift.
///
/// Пакет не открывает платформенное подключение: `QueryExecutor` передаёт
/// фабрика соответствующего пакета `platform_*`.
///
/// Публичные API базы данных, запросов, EventStore и очистки не зависят от
/// платформы. Создайте AppDatabase с платформенным QueryExecutor и передайте
/// его в DriftEventStore.

export 'src/database/app_database.dart';
export 'src/database/schema.dart';
export 'src/models/event_data.dart';
export 'src/models/storage_info.dart';
export 'src/blob_store_impl.dart';
export 'src/event_store_impl.dart';
export 'src/group_metadata_store_impl.dart';
export 'src/retention.dart';
export 'src/platform/storage_backend_result.dart';
