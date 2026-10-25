import 'dart:typed_data';

import '../interfaces/thumbnail_generator.dart';
import '../result.dart';

class FileManifest {
  const FileManifest({
    required this.fileId,
    required this.fileName,
    required this.mimeType,
    required this.size,
    required this.chunkSize,
    required this.chunkCount,
    required this.leafHashes,
    this.groupId = '',
  });

  final String fileId;
  final String fileName;
  final String mimeType;
  final int size;
  final int chunkSize;
  final int chunkCount;
  final List<String> leafHashes;

  /// Группа, к которой относится блоб (для групповой квоты).
  final String groupId;
}

class FileTransferResult {
  const FileTransferResult({
    required this.fileId,
    required this.completed,
    required this.received,
    required this.missing,
    required this.chunksBySource,
  });

  final String fileId;
  final bool completed;
  final int received;
  final List<int> missing;
  final Map<String, int> chunksBySource;
}

abstract final class FileLimits {
  static const int chunkSize = 16 * 1024;
  static const int maxFileBytes = 100 * 1024 * 1024;
  static const int maxWindow = 32;
  static const int maxSources = 3;
}

sealed class FileTransferError {
  const FileTransferError();
}

class FileTooLarge extends FileTransferError {
  const FileTooLarge(this.size, this.limit);
  final int size;
  final int limit;

  @override
  String toString() => 'FileTooLarge($size > $limit)';
}

class InvalidManifest extends FileTransferError {
  const InvalidManifest(this.reason);
  final String reason;

  @override
  String toString() => 'InvalidManifest($reason)';
}

class GroupQuotaExceeded extends FileTransferError {
  const GroupQuotaExceeded(this.groupId, this.used, this.limit, this.requested);
  final String groupId;
  final int used;
  final int limit;
  final int requested;

  @override
  String toString() =>
      'GroupQuotaExceeded(group=$groupId, $used + $requested > $limit)';
}

class QuotaExceeded extends FileTransferError {
  const QuotaExceeded(this.used, this.limit, this.requested);
  final int used;
  final int limit;
  final int requested;

  @override
  String toString() => 'QuotaExceeded($used + $requested > $limit)';
}

class SourcesExhausted extends FileTransferError {
  const SourcesExhausted(this.missing);
  final List<int> missing;

  @override
  String toString() => 'SourcesExhausted(${missing.length} chunks)';
}

class BlobStorageFailure extends FileTransferError {
  const BlobStorageFailure(this.error);
  final Object error;

  @override
  String toString() => 'BlobStorageFailure($error)';
}

class ThumbnailFailed extends FileTransferError {
  const ThumbnailFailed(this.error);
  final ThumbnailError error;

  @override
  String toString() => 'ThumbnailFailed($error)';
}

abstract class BlobStore {
  Future<void> writeChunk(
    String fileId,
    int index,
    List<int> bytes, {
    String? groupId,
  });

  Future<List<int>?> readChunk(String fileId, int index);

  Future<Set<int>> receivedChunks(String fileId);

  Future<int> totalBytes();

  Future<int> totalBytesForGroup(String groupId);

  Future<void> clear(String fileId);
}

abstract class BlobSource {
  String get peerId;

  Future<List<int>?> fetchChunk(String fileId, int index);
}

abstract class FileTransferService {
  Future<Result<FileManifest, FileTransferError>> prepare(
    Uint8List bytes, {
    String fileName = 'file',
    String mimeType = 'application/octet-stream',
    int chunkSize = FileLimits.chunkSize,
    String groupId = '',
  });

  Future<Result<FileTransferResult, FileTransferError>> download(
    FileManifest manifest,
    List<BlobSource> sources, {
    int maxSources = FileLimits.maxSources,
    int window = 8,
    String? groupId,
  });

  Future<Result<void, FileTransferError>> seed(
    FileManifest manifest,
    Uint8List bytes, {
    String? groupId,
  });

  Future<Result<Uint8List, FileTransferError>> readAll(FileManifest manifest);

  /// Миниатюра для изображения. Для не-изображений и без генератора — `Ok(null)`.
  Future<Result<ImageThumbnail?, FileTransferError>> preview(
    FileManifest manifest,
    Uint8List bytes, {
    int maxEdge = 512,
    int maxBytes = 256 * 1024,
  });

  Future<void> close();
}
