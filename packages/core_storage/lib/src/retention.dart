import 'database/app_database.dart';

/// Метаданные истёкшего blob-а, передаваемые в callback удаления.
class ExpiredBlob {
  const ExpiredBlob({
    required this.id,
    required this.groupId,
    required this.filename,
    required this.mimeType,
    required this.size,
    required this.createdAt,
    required this.expiresAt,
    this.channelId,
    this.messageId,
  });

  factory ExpiredBlob.fromRow(Map<String, Object?> row) => ExpiredBlob(
    id: row['id'] as String,
    groupId: row['group_id'] as String,
    channelId: row['channel_id'] as String?,
    messageId: row['message_id'] as String?,
    filename: row['filename'] as String,
    mimeType: row['mime_type'] as String,
    size: int.parse(row['size']!.toString()),
    createdAt: int.parse(row['created_at']!.toString()),
    expiresAt: int.parse(row['expires_at']!.toString()),
  );

  final String id;
  final String groupId;
  final String? channelId;
  final String? messageId;
  final String filename;
  final String mimeType;
  final int size;
  final int createdAt;
  final int expiresAt;
}

/// Ошибка удаления одного blob-а.
class RetentionFailure {
  const RetentionFailure({
    required this.blob,
    required this.error,
    this.stackTrace,
  });

  final ExpiredBlob blob;
  final Object error;
  final StackTrace? stackTrace;
}

/// Результат одного прохода retention.
class RetentionResult {
  const RetentionResult({
    required this.deleted,
    required this.failures,
  });

  /// Число blob-ов, у которых файл и metadata удалены успешно.
  final int deleted;

  /// Ошибки удаления; metadata таких blob-ов сохранена для повтора.
  final List<RetentionFailure> failures;

  bool get isComplete => failures.isEmpty;
}

/// Удаление blob-файла по метаданным.
typedef BlobDeleteCallback = Future<void> Function(ExpiredBlob blob);

/// Retention policy for attachments / blobs.
///
/// [run] сначала удаляет файл через callback, затем metadata. Если callback
/// завершился ошибкой, metadata остаётся для повторного прохода.
class RetentionPolicy {
  final AppDatabase _db;

  RetentionPolicy(this._db);

  /// Удаляет истёкшие blob-файлы и их metadata.
  ///
  /// События и другие таблицы не затрагиваются. Ошибка удаления файла
  /// попадает в [RetentionResult.failures], metadata сохраняется.
  Future<RetentionResult> run(
    int beforeTimestamp, {
    required BlobDeleteCallback deleteBlob,
  }) async {
    final rows = await _db.selectExpiredBlobs(beforeTimestamp);
    var deleted = 0;
    final failures = <RetentionFailure>[];

    for (final row in rows) {
      final blob = ExpiredBlob.fromRow(row);
      try {
        await deleteBlob(blob);
        await _db.deleteBlobMeta(blob.id);
        deleted++;
      } catch (error, stackTrace) {
        failures.add(
          RetentionFailure(
            blob: blob,
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
    }

    return RetentionResult(deleted: deleted, failures: failures);
  }

  /// Удаляет только metadata истёкших blob-ов, без удаления файлов.
  ///
  /// Оставлено для случаев, когда вызывающий слой уже удалил файлы сам.
  /// Для полного прохода используйте [run].
  Future<int> expireBlobs(int beforeTimestamp) async {
    return await _db.expireBlobs(beforeTimestamp);
  }

  /// Возвращает metadata истёкших, но ещё не удалённых blob-ов.
  Future<List<Map<String, Object?>>> expiredBlobs(int beforeTimestamp) async {
    return await _db.selectExpiredBlobs(beforeTimestamp);
  }
}
