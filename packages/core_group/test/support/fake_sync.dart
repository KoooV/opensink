import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:core_sync/core_sync.dart';

/// Тестовая идентичность: автор — 32-байтный hex, подпись детерминированная.
class FakeIdentity {
  FakeIdentity(this.author) : signer = FakeSigner(author.value);

  final UserId author;
  final FakeSigner signer;
}

class FakeSigner implements Signer {
  FakeSigner(this._authorHex);

  final String _authorHex;

  @override
  Future<String> sign(Uint8List data) async => _signature(_authorHex, data);

  @override
  Future<bool> verify(
    Uint8List data,
    String signatureHex,
    PeerId peerId,
  ) async => signatureHex == _signature(_hex(peerId.publicKey), data);

  String _signature(String authorHex, Uint8List data) =>
      '$authorHex:${base64Encode(data)}';

  String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

UserId testUserId(int index) {
  final byte = index.toRadixString(16).padLeft(2, '0');
  return UserId(byte * 32);
}

/// In-memory реализация `SyncEventStore` для тестов моста.
class MemorySyncEventStore implements SyncEventStore {
  final Map<String, EventRecord> _records = {};
  final Map<String, EventRecord> _pending = {};

  int get length => _records.length;

  /// Тестовая подмена записи (например, для проверки подписи при restore).
  void replace(EventRecord record) {
    _records[record.id] = record;
  }

  @override
  Future<Result<InsertOutcome, EventStoreWriteError>> write(
    EventRecord record,
  ) async {
    if (_records.containsKey(record.id)) {
      return const Ok(InsertOutcome(inserted: false, duplicate: true));
    }
    _records[record.id] = record;
    return const Ok(InsertOutcome(inserted: true, duplicate: false));
  }

  @override
  Stream<EventRecord> watchFrom(String cursor) async* {
    var emitting = cursor.isEmpty;
    for (final record in _sortedAll()) {
      if (!emitting && record.id == cursor) emitting = true;
      if (emitting) yield record;
    }
  }

  @override
  Stream<EventRecord> watchGroup(GroupId groupId) async* {
    for (final record in _sortedAll()) {
      if (record.groupId == groupId) yield record;
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<List<EventRecord>> groupEvents(
    GroupId groupId, {
    int? limit,
    int? offset,
  }) async {
    return _sortedAll()
        .where((record) => record.groupId == groupId)
        .skip(offset ?? 0)
        .take(limit ?? 1 << 31)
        .toList();
  }

  @override
  Future<List<EventRecord>> eventsInRange(
    GroupId groupId, {
    required int hlcFrom,
    required int hlcTo,
    int limit = 256,
    int? afterHlc,
    String? afterId,
    ChannelId? channelId,
  }) async {
    final result = <EventRecord>[];
    for (final record in _sortedAll()) {
      if (record.groupId != groupId) continue;
      if (channelId != null && record.channelId != channelId) continue;
      if (record.timestamp < hlcFrom || record.timestamp > hlcTo) continue;
      if (afterHlc != null && afterId != null) {
        if (record.timestamp < afterHlc) continue;
        if (record.timestamp == afterHlc && record.id.compareTo(afterId) <= 0) {
          continue;
        }
      }
      result.add(record);
      if (result.length >= limit) break;
    }
    return result;
  }

  @override
  Future<List<EventRecord>> latestChannelEvents(
    GroupId groupId,
    ChannelId channelId, {
    int limit = 50,
  }) async {
    final result =
        _records.values
            .where(
              (record) =>
                  record.groupId == groupId && record.channelId == channelId,
            )
            .toList()
          ..sort((a, b) {
            final byHlc = b.timestamp.compareTo(a.timestamp);
            if (byHlc != 0) return byHlc;
            return b.id.compareTo(a.id);
          });
    return result.take(limit).toList();
  }

  @override
  Future<EventRecord?> eventById(String id) async => _records[id];

  @override
  Future<List<EventRecord>> pendingEvents(
    GroupId groupId, {
    int limit = 256,
  }) async {
    return _pending.values
        .where((record) => record.groupId == groupId)
        .take(limit)
        .toList();
  }

  @override
  Future<void> putPendingEvent(EventRecord record) async {
    _pending[record.id] = record;
  }

  @override
  Future<void> deletePendingEvent(String id) async {
    _pending.remove(id);
  }

  List<EventRecord> _sortedAll() {
    return _records.values.toList()..sort((a, b) {
      final byHlc = a.timestamp.compareTo(b.timestamp);
      if (byHlc != 0) return byHlc;
      return a.id.compareTo(b.id);
    });
  }
}

/// Создаёт подписанное событие от имени удалённого участника.
Future<SyncEvent> signedEventWith({
  required FakeIdentity identity,
  required GroupEvent draft,
  required Hlc hlc,
  GroupEventCodec? codec,
}) async {
  final eventCodec = codec ?? const GroupEventCodec();
  final payload = eventCodec.encode(draft).unwrap();
  final base = SyncEvent(
    id: const EventId(''),
    groupId: draft.groupId,
    authorId: identity.author,
    hlc: hlc,
    kind: eventCodec.kindOf(draft),
    channelId: eventCodec.channelIdOf(draft),
    targetId: eventCodec.targetIdOf(draft),
    payload: payload,
  );
  final withId = base.copyWith(id: EventId(base.computeId()));
  final signature = await identity.signer.sign(withId.signedBytes());
  return withId.copyWith(signature: signature);
}
