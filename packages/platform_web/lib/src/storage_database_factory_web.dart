import 'dart:js_interop';

import 'package:core_storage/core_storage.dart';
import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
// ignore: experimental_member_use
import 'package:sqlite3/wasm.dart';
import 'package:web/web.dart';

/// Фабрика SQLite WASM для веб-платформы.
///
/// Ресурсы должны быть same-origin и доступны по переданным URI. Отсутствующий
/// ресурс или неверный MIME-тип сообщается через [ResourceMissing].
class WebDatabaseFactory implements StorageBackend {
  WebDatabaseFactory({
    Uri? sqlite3Uri,
    Uri? driftWorkerUri,
  }) : _sqlite3Uri = sqlite3Uri ?? Uri.parse('sqlite3.wasm'),
       _driftWorkerUri = driftWorkerUri ?? Uri.parse('drift_worker.js');

  final Uri _sqlite3Uri;
  final Uri _driftWorkerUri;

  @override
  Future<OpenedStorage> open(StorageSpec spec) async {
    QueryExecutor? executor;
    try {
      await _verifyResource(
        _sqlite3Uri,
        'sqlite3.wasm',
        acceptedContentTypes: const {'application/wasm'},
      );

      if (spec.inMemory) {
        final sqlite3 = await WasmSqlite3.loadFromUrl(_sqlite3Uri);
        sqlite3.registerVirtualFileSystem(
          InMemoryFileSystem(),
          makeDefault: true,
        );
        executor = WasmDatabase.inMemory(sqlite3);
        final info = await AppDatabase(executor).open(
          backend: 'memory',
          isPersistent: false,
          warnings: const [
            'Режим памяти: данные не сохраняются после закрытия или перезагрузки страницы.',
          ],
        );
        return OpenedStorage(executor: executor, info: info);
      }

      await _verifyResource(
        _driftWorkerUri,
        'drift_worker.js',
        acceptedContentTypes: const {
          'application/javascript',
          'text/javascript',
          'application/x-javascript',
        },
      );

      final result = await WasmDatabase.open(
        databaseName: spec.name,
        sqlite3Uri: _sqlite3Uri,
        driftWorkerUri: _driftWorkerUri,
      );
      executor = result.resolvedExecutor;

      final implementation = result.chosenImplementation;
      final backend = switch (implementation) {
        WasmStorageImplementation.opfsShared ||
        WasmStorageImplementation.opfsLocks => 'opfs',
        WasmStorageImplementation.sharedIndexedDb ||
        WasmStorageImplementation.unsafeIndexedDb => 'indexedDb',
        WasmStorageImplementation.inMemory => 'memory',
      };
      final isPersistent =
          implementation != WasmStorageImplementation.inMemory;
      final warnings = _warningsFor(implementation, result.missingFeatures);
      final info = await AppDatabase(executor).open(
        backend: backend,
        isPersistent: isPersistent,
        warnings: warnings,
      );
      return OpenedStorage(executor: executor, info: info);
    } on StorageOpenError {
      await _closeOnFailure(executor);
      rethrow;
    } catch (error, stack) {
      await _closeOnFailure(executor);
      throw OpenFailure(error, stack);
    }
  }

  static List<String> _warningsFor(
    WasmStorageImplementation implementation,
    Set<MissingBrowserFeature> missingFeatures,
  ) {
    final warnings = <String>[];
    switch (implementation) {
      case WasmStorageImplementation.unsafeIndexedDb:
        warnings.add(
          'Выбран IndexedDB без межвкладочной синхронизации. '
          'Не открывайте эту БД одновременно в нескольких вкладках.',
        );
      case WasmStorageImplementation.inMemory:
        warnings.add(
          'Браузер не предоставил персистентный backend: данные не сохраняются после перезагрузки страницы.',
        );
      case WasmStorageImplementation.opfsShared:
      case WasmStorageImplementation.opfsLocks:
      case WasmStorageImplementation.sharedIndexedDb:
        break;
    }
    if (missingFeatures.isNotEmpty) {
      warnings.add(
        'Ограничения браузера для drift: '
        '${missingFeatures.map((feature) => feature.name).join(', ')}.',
      );
    }
    return warnings;
  }

  static Future<void> _verifyResource(
    Uri uri,
    String name, {
    required Set<String> acceptedContentTypes,
  }) async {
    try {
      final response = await window.fetch(uri.toString().toJS).toDart;
      if (!response.ok) {
        throw ResourceMissing('$name (HTTP ${response.status})');
      }
      final contentType = response.headers.get('content-type')
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (contentType == null || !acceptedContentTypes.contains(contentType)) {
        throw ResourceMissing(
          '$name (неподдерживаемый Content-Type: ${contentType ?? 'отсутствует'})',
        );
      }
    } on StorageOpenError {
      rethrow;
    } on Object catch (error) {
      throw ResourceMissing('$name недоступен по $uri: $error');
    }
  }

  static Future<void> _closeOnFailure(QueryExecutor? executor) async {
    if (executor == null) return;
    try {
      await executor.close();
    } on Object catch (_) {
      // Исходная типизированная ошибка важнее ошибки закрытия.
    }
  }
}
