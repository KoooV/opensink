import 'dart:async';
import 'dart:typed_data';

import '../models/file_transfer.dart';
import '../models/notification.dart';
import '../models/presence.dart';
import '../result.dart';
import 'thumbnail_generator.dart';

class MemoryBlobStore implements BlobStore {
  final Map<String, Map<int, Uint8List>> _chunks = {};
  int _bytes = 0;

  @override
  Future<void> writeChunk(String fileId, int index, List<int> bytes) async {
    final file = _chunks.putIfAbsent(fileId, () => <int, Uint8List>{});
    final previous = file[index];
    if (previous != null) _bytes -= previous.length;
    final copy = Uint8List.fromList(bytes);
    file[index] = copy;
    _bytes += copy.length;
  }

  @override
  Future<List<int>?> readChunk(String fileId, int index) async {
    final value = _chunks[fileId]?[index];
    return value == null ? null : List<int>.from(value);
  }

  @override
  Future<Set<int>> receivedChunks(String fileId) async {
    return Set<int>.from(_chunks[fileId]?.keys ?? const <int>[]);
  }

  @override
  Future<int> totalBytes() async => _bytes;

  @override
  Future<void> clear(String fileId) async {
    final file = _chunks.remove(fileId);
    if (file == null) return;
    for (final chunk in file.values) {
      _bytes -= chunk.length;
    }
  }

  int get chunkCount {
    var count = 0;
    for (final file in _chunks.values) {
      count += file.length;
    }
    return count;
  }
}

class FakeEphemeralChatBus implements EphemeralChatBus {
  final StreamController<EphemeralChatEvent> _incoming =
      StreamController<EphemeralChatEvent>.broadcast();
  final List<EphemeralChatEvent> published = <EphemeralChatEvent>[];

  @override
  Stream<EphemeralChatEvent> get incoming => _incoming.stream;

  @override
  Future<void> publish(EphemeralChatEvent event) async {
    published.add(event);
    _incoming.add(event);
  }

  void emit(EphemeralChatEvent event) => _incoming.add(event);

  @override
  Future<void> close() async {
    await _incoming.close();
  }
}

class FakeNotificationService implements NotificationService {
  final List<ChatNotification> shown = <ChatNotification>[];
  final List<String> cancelled = <String>[];
  bool allCancelled = false;

  @override
  Future<void> show(ChatNotification notification) async {
    shown.add(notification);
  }

  @override
  Future<void> cancel(String id) async {
    cancelled.add(id);
  }

  @override
  Future<void> cancelAll() async {
    allCancelled = true;
    cancelled.addAll(shown.map((notification) => notification.id));
  }
}

class FakeThumbnailGenerator implements ThumbnailGenerator {
  ImageThumbnail? next;

  @override
  Future<Result<ImageThumbnail?, ThumbnailError>> generate(
    Uint8List source, {
    int maxEdge = 512,
    int maxBytes = 256 * 1024,
  }) async {
    return Ok(next);
  }
}
