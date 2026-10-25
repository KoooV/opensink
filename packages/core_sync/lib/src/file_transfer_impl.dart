import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:crypto/crypto.dart';

import 'bytes.dart';

class FileTransferServiceImpl implements FileTransferService {
  FileTransferServiceImpl({
    required this.store,
    this.maxStoreBytes,
    this.maxGroupStoreBytes,
    this.thumbnails,
  });

  final BlobStore store;
  final int? maxStoreBytes;
  final int? maxGroupStoreBytes;
  final ThumbnailGenerator? thumbnails;

  @override
  Future<Result<FileManifest, FileTransferError>> prepare(
    Uint8List bytes, {
    String fileName = 'file',
    String mimeType = 'application/octet-stream',
    int chunkSize = FileLimits.chunkSize,
    String groupId = '',
  }) async {
    if (bytes.length > FileLimits.maxFileBytes) {
      return Err(FileTooLarge(bytes.length, FileLimits.maxFileBytes));
    }
    if (chunkSize <= 0 || chunkSize > 256 * 1024) {
      return const Err(InvalidManifest('invalid chunk size'));
    }
    final leafHashes = <String>[];
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize < bytes.length)
          ? offset + chunkSize
          : bytes.length;
      leafHashes.add(sha256.convert(bytes.sublist(offset, end)).toString());
    }
    if (leafHashes.isEmpty) {
      leafHashes.add(sha256.convert(const <int>[]).toString());
    }
    final root = _merkleRoot(leafHashes);
    return Ok(
      FileManifest(
        fileId: root,
        fileName: fileName,
        mimeType: mimeType,
        size: bytes.length,
        chunkSize: chunkSize,
        chunkCount: leafHashes.length,
        leafHashes: List<String>.unmodifiable(leafHashes),
        groupId: groupId,
      ),
    );
  }

  @override
  Future<Result<void, FileTransferError>> seed(
    FileManifest manifest,
    Uint8List bytes, {
    String? groupId,
  }) async {
    final invalid = _validate(manifest);
    if (invalid != null) return Err(invalid);
    final effectiveGroup = _effectiveGroupId(manifest, groupId);
    if (effectiveGroup == null) {
      return const Err(InvalidManifest('group id mismatch'));
    }
    if (bytes.length != manifest.size) {
      return const Err(InvalidManifest('size mismatch'));
    }
    final received = await store.receivedChunks(manifest.fileId);
    final missingBytes = _missingBytes(manifest, received);
    final quota = await _checkQuota(effectiveGroup, missingBytes);
    if (quota != null) return Err(quota);
    for (var index = 0; index < manifest.chunkCount; index++) {
      if (received.contains(index)) continue;
      final offset = index * manifest.chunkSize;
      final end = (offset + manifest.chunkSize < bytes.length)
          ? offset + manifest.chunkSize
          : bytes.length;
      await store.writeChunk(
        manifest.fileId,
        index,
        bytes.sublist(offset, end),
        groupId: effectiveGroup,
      );
    }
    return const Ok(null);
  }

  @override
  Future<Result<FileTransferResult, FileTransferError>> download(
    FileManifest manifest,
    List<BlobSource> sources, {
    int maxSources = FileLimits.maxSources,
    int window = 8,
    String? groupId,
  }) async {
    final invalid = _validate(manifest);
    if (invalid != null) return Err(invalid);
    final effectiveGroup = _effectiveGroupId(manifest, groupId);
    if (effectiveGroup == null) {
      return const Err(InvalidManifest('group id mismatch'));
    }
    final selected = sources
        .take(maxSources.clamp(1, FileLimits.maxSources))
        .toList();
    final received = await store.receivedChunks(manifest.fileId);
    final missing = <int>[
      for (var index = 0; index < manifest.chunkCount; index++)
        if (!received.contains(index)) index,
    ];
    if (missing.isNotEmpty) {
      final quota = await _checkQuota(
        effectiveGroup,
        _missingBytes(manifest, received),
      );
      if (quota != null) return Err(quota);
      if (selected.isEmpty) return Err(SourcesExhausted(missing));
    }

    final chunksBySource = <String, int>{};
    final batchSize = window.clamp(1, FileLimits.maxWindow);
    for (var start = 0; start < missing.length; start += batchSize) {
      final end = (start + batchSize < missing.length)
          ? start + batchSize
          : missing.length;
      final batch = missing.sublist(start, end);
      await Future.wait(
        batch.map((index) async {
          final source = await _fetchVerified(
            manifest,
            selected,
            index,
            chunksBySource,
            effectiveGroup,
          );
          return source;
        }),
      );
    }

    final after = await store.receivedChunks(manifest.fileId);
    final stillMissing = <int>[
      for (var index = 0; index < manifest.chunkCount; index++)
        if (!after.contains(index)) index,
    ];
    return Ok(
      FileTransferResult(
        fileId: manifest.fileId,
        completed: stillMissing.isEmpty,
        received: manifest.chunkCount - stillMissing.length,
        missing: List<int>.unmodifiable(stillMissing),
        chunksBySource: Map<String, int>.unmodifiable(chunksBySource),
      ),
    );
  }

  Future<bool> _fetchVerified(
    FileManifest manifest,
    List<BlobSource> sources,
    int index,
    Map<String, int> chunksBySource,
    String effectiveGroup,
  ) async {
    if (sources.isEmpty) return false;
    final offset = index % sources.length;
    for (var attempt = 0; attempt < sources.length; attempt++) {
      final source = sources[(offset + attempt) % sources.length];
      List<int>? data;
      try {
        data = await source.fetchChunk(manifest.fileId, index);
      } catch (_) {
        continue;
      }
      if (data == null) continue;
      final expected = _chunkLength(manifest, index);
      if (data.length != expected) continue;
      final hash = sha256.convert(data).toString();
      if (hash != manifest.leafHashes[index]) continue;
      await store.writeChunk(
        manifest.fileId,
        index,
        data,
        groupId: effectiveGroup,
      );
      chunksBySource[source.peerId] = (chunksBySource[source.peerId] ?? 0) + 1;
      return true;
    }
    return false;
  }

  @override
  Future<Result<ImageThumbnail?, FileTransferError>> preview(
    FileManifest manifest,
    Uint8List bytes, {
    int maxEdge = 512,
    int maxBytes = 256 * 1024,
  }) async {
    final invalid = _validate(manifest);
    if (invalid != null) return Err(invalid);
    if (bytes.length != manifest.size) {
      return const Err(InvalidManifest('size mismatch'));
    }
    if (!manifest.mimeType.toLowerCase().startsWith('image/')) {
      return const Ok(null);
    }
    final generator = thumbnails;
    if (generator == null) return const Ok(null);
    final generated = await generator.generate(
      bytes,
      maxEdge: maxEdge,
      maxBytes: maxBytes,
    );
    if (generated.isErr) return Err(ThumbnailFailed(generated.unwrapErr()));
    return Ok(generated.unwrap());
  }

  @override
  Future<Result<Uint8List, FileTransferError>> readAll(
    FileManifest manifest,
  ) async {
    final invalid = _validate(manifest);
    if (invalid != null) return Err(invalid);
    final received = await store.receivedChunks(manifest.fileId);
    final builder = BytesBuilder(copy: false);
    for (var index = 0; index < manifest.chunkCount; index++) {
      if (!received.contains(index)) {
        return const Err(SourcesExhausted(<int>[]));
      }
      final chunk = await store.readChunk(manifest.fileId, index);
      if (chunk == null) return const Err(SourcesExhausted(<int>[]));
      final hash = sha256.convert(chunk).toString();
      if (hash != manifest.leafHashes[index]) {
        return const Err(InvalidManifest('chunk hash mismatch'));
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != manifest.size) {
      return const Err(InvalidManifest('size mismatch'));
    }
    if (_merkleRoot(manifest.leafHashes) != manifest.fileId) {
      return const Err(InvalidManifest('root mismatch'));
    }
    return Ok(bytes);
  }

  String? _effectiveGroupId(FileManifest manifest, String? explicit) {
    final requested = explicit?.trim();
    if (requested != null &&
        requested.isNotEmpty &&
        manifest.groupId.isNotEmpty &&
        requested != manifest.groupId) {
      return null;
    }
    if (requested != null && requested.isNotEmpty) return requested;
    return manifest.groupId;
  }

  InvalidManifest? _validate(FileManifest manifest) {
    if (manifest.size < 0 || manifest.size > FileLimits.maxFileBytes) {
      return const InvalidManifest('invalid size');
    }
    if (manifest.chunkSize <= 0) {
      return const InvalidManifest('invalid chunk size');
    }
    if (manifest.chunkCount <= 0 ||
        manifest.chunkCount != manifest.leafHashes.length) {
      return const InvalidManifest('chunk count mismatch');
    }
    final expectedCount =
        (manifest.size + manifest.chunkSize - 1) ~/ manifest.chunkSize;
    if (expectedCount != manifest.chunkCount) {
      return const InvalidManifest('chunk count does not match size');
    }
    if (_merkleRoot(manifest.leafHashes) != manifest.fileId) {
      return const InvalidManifest('root mismatch');
    }
    return null;
  }

  Future<FileTransferError?> _checkQuota(String groupId, int requested) async {
    final limit = maxStoreBytes;
    if (limit != null) {
      final used = await store.totalBytes();
      if (used + requested > limit) {
        return QuotaExceeded(used, limit, requested);
      }
    }
    final groupLimit = maxGroupStoreBytes;
    if (groupId.isNotEmpty && groupLimit != null) {
      final used = await store.totalBytesForGroup(groupId);
      if (used + requested > groupLimit) {
        return GroupQuotaExceeded(groupId, used, groupLimit, requested);
      }
    }
    return null;
  }

  int _missingBytes(FileManifest manifest, Set<int> received) {
    var total = 0;
    for (var index = 0; index < manifest.chunkCount; index++) {
      if (received.contains(index)) continue;
      total += _chunkLength(manifest, index);
    }
    return total;
  }

  int _chunkLength(FileManifest manifest, int index) {
    final offset = index * manifest.chunkSize;
    final end = (offset + manifest.chunkSize < manifest.size)
        ? offset + manifest.chunkSize
        : manifest.size;
    return end - offset;
  }

  String _merkleRoot(List<String> leaves) {
    if (leaves.isEmpty) return sha256.convert(const <int>[]).toString();
    var level = leaves.map((leaf) => hexDecode(leaf) ?? const <int>[]).toList();
    while (level.length > 1) {
      final next = <List<int>>[];
      for (var index = 0; index < level.length; index += 2) {
        if (index + 1 >= level.length) {
          next.add(level[index]);
          continue;
        }
        next.add(<int>[...level[index], ...level[index + 1]]);
      }
      level = next.map((bytes) => sha256.convert(bytes).bytes).toList();
    }
    return hexEncode(level.first);
  }

  @override
  Future<void> close() async {}
}
