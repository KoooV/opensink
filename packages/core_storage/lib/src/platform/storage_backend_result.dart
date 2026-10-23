import 'package:core_domain/core_domain.dart';

import '../models/storage_info.dart';

/// Безопасный вариант открытия: инфраструктурные сбои возвращаются типизированно.
///
/// Основной контракт [StorageBackend.open] сохраняет поведение, утверждённое
/// ADR 4.1; вызывающий код, которому нужен `Result`, использует этот метод.
extension StorageBackendResult on StorageBackend {
  Future<Result<OpenedStorage, StorageOpenError>> openResult(
    StorageSpec spec,
  ) async {
    try {
      return Ok(await open(spec));
    } on StorageOpenError catch (error) {
      return Err(error);
    } catch (error, stack) {
      return Err(OpenFailure(error, stack));
    }
  }
}
