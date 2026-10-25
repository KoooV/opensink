import 'dart:typed_data';

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
  });

  final String fileId;
  final String fileName;
  final String mimeType;
  final int size;
  final int chunkSize;
  final int chunkCount;
  final List<String> leafHashes;
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

abstract class BlobStore {
  Future<void> writeChunk(String fileId, int index, List<int> bytes);

  Future<List<int>?> readChunk(String fileId, int index);

  Future<Set<int>> receivedChunks(String fileId);

  Future<int> totalBytes();

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
  });

  Future<Result<FileTransferResult, FileTransferError>> download(
    FileManifest manifest,
    List<BlobSource> sources, {
    int maxSources = FileLimits.maxSources,
    int window = 8,
  });

  Future<Result<void, FileTransferError>> seed(
    FileManifest manifest,
    Uint8List bytes,
  );

  Future<Result<Uint8List, FileTransferError>> readAll(FileManifest manifest);

  Future<void> close();
}
