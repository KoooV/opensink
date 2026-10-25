import 'package:core_domain/core_domain.dart';

import 'database/app_database.dart';

/// Персистентный [BlobStore] поверх SQLite (`blob_transfers`, schema v8).
///
/// Чанки лежат в той же базе, что и журнал событий, поэтому доступны после
/// рестарта на Android, Linux и Web без отдельных файловых API.
class DriftBlobStore implements BlobStore {
  DriftBlobStore(this._db, {int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase _db;
  final int Function() _nowMs;

  @override
  Future<void> writeChunk(String fileId, int index, List<int> bytes) {
    if (fileId.isEmpty || index < 0) {
      throw ArgumentError('invalid blob chunk identity');
    }
    return _db.writeBlobChunk(
      fileId: fileId,
      chunkIndex: index,
      bytes: bytes,
      receivedAt: _nowMs(),
    );
  }

  @override
  Future<List<int>?> readChunk(String fileId, int index) async {
    if (fileId.isEmpty || index < 0) return null;
    final stored = await _db.readBlobChunk(fileId, index);
    return stored == null ? null : List<int>.from(stored);
  }

  @override
  Future<Set<int>> receivedChunks(String fileId) {
    if (fileId.isEmpty) return Future<Set<int>>.value(<int>{});
    return _db.receivedBlobChunks(fileId);
  }

  @override
  Future<int> totalBytes() => _db.blobTotalBytes();

  @override
  Future<void> clear(String fileId) {
    if (fileId.isEmpty) return Future<void>.value();
    return _db.clearBlob(fileId);
  }
}
