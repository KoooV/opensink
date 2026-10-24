import 'dart:async';

import 'package:core_domain/core_domain.dart';

class MemorySyncEventStore implements SyncEventStore {
  final Map<String, EventRecord> _records = {};
  final Map<String, EventRecord> _pending = {};
  final StreamController<EventRecord> _writes =
      StreamController<EventRecord>.broadcast();
  bool closed = false;

  int get length => _records.length;

  int get pendingLength => _pending.length;

  @override
  Future<Result<InsertOutcome, EventStoreWriteError>> write(
    EventRecord record,
  ) async {
    if (closed) return const Err(StorageWriteError());
    if (_records.containsKey(record.id)) {
      return const Ok(InsertOutcome(inserted: false, duplicate: true));
    }
    _records[record.id] = record;
    _writes.add(record);
    return const Ok(InsertOutcome(inserted: true, duplicate: false));
  }

  @override
  Stream<EventRecord> watchFrom(String cursor) async* {
    final all = _sortedAll();
    var started = cursor.isEmpty;
    for (final record in all) {
      if (!started && record.id == cursor) started = true;
      if (started) yield record;
    }
    yield* _writes.stream;
  }

  @override
  Stream<EventRecord> watchGroup(GroupId groupId) async* {
    for (final record in _sortedAll()) {
      if (record.groupId == groupId) yield record;
    }
    yield* _writes.stream.where((record) => record.groupId == groupId);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _writes.close();
  }

  @override
  Future<List<EventRecord>> groupEvents(
    GroupId groupId, {
    int? limit,
    int? offset,
  }) async {
    final result = _sortedAll()
        .where((record) => record.groupId == groupId)
        .skip(offset ?? 0)
        .take(limit ?? 1 << 31)
        .toList();
    return result;
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
    final result =
        _pending.values.where((record) => record.groupId == groupId).toList()
          ..sort((a, b) {
            final byHlc = a.timestamp.compareTo(b.timestamp);
            if (byHlc != 0) return byHlc;
            return a.id.compareTo(b.id);
          });
    return result.take(limit).toList();
  }

  @override
  Future<void> putPendingEvent(EventRecord record) async {
    if (closed) throw StateError('store is closed');
    _pending[record.id] = record;
  }

  @override
  Future<void> deletePendingEvent(String id) async {
    if (closed) throw StateError('store is closed');
    _pending.remove(id);
  }

  List<EventRecord> _sortedAll() {
    final all = _records.values.toList()
      ..sort((a, b) {
        final byHlc = a.timestamp.compareTo(b.timestamp);
        if (byHlc != 0) return byHlc;
        return a.id.compareTo(b.id);
      });
    return all;
  }
}
