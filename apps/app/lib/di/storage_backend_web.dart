import 'package:core_storage/core_storage.dart';
import 'package:platform_web/platform_web.dart';

/// SQLite WASM для web (OPFS/IndexedDB с деградацией до memory).
StorageBackend createPlatformStorageBackend() => WebDatabaseFactory();
