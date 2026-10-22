import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';

/// A single event row from the events log.
class EventData {
  const EventData({
    required this.id,
    required this.groupId,
    required this.author,
    required this.hlc,
    required this.bytes,
    required this.signature,
    this.channelId,
  });

  final String id;
  final String groupId;
  final String author;
  final int hlc;
  final Uint8List bytes;
  final String signature;
  final String? channelId;

  /// Converts to an [EventRecord] for the domain layer.
  EventRecord toEventRecord() => EventRecord(
        id: id,
        groupId: GroupId(groupId),
        channelId: channelId == null ? null : ChannelId(channelId!),
        author: author,
        payload: bytes,
        timestamp: hlc,
        signature: signature,
      );

  @override
  String toString() => 'EventData(id=$id, groupId=$groupId, hlc=$hlc)';
}

/// Ошибка построения range summary.
sealed class RangeSummaryError implements Exception {
  const RangeSummaryError();
}

/// Диапазон содержит больше событий, чем разрешено одним запросом.
class RangeTooLarge extends RangeSummaryError {
  const RangeTooLarge(this.limit);

  final int limit;

  @override
  String toString() =>
      'Range contains more than $limit events; narrow the hlc range';
}

/// Result of rangeSummary.
class RangeSummary {
  const RangeSummary({
    required this.count,
    required this.rangeHash,
    required this.hlcFrom,
    required this.hlcTo,
  });

  final int count;
  final Uint8List rangeHash;
  final int hlcFrom;
  final int hlcTo;

  String get rangeHashHex => rangeHex(rangeHash);

  @override
  String toString() =>
      'RangeSummary(count=$count, hlc=$hlcFrom..$hlcTo, hash=$rangeHashHex)';
}

/// A page of channel events for UI consumption.
class ChannelPage {
  const ChannelPage({
    required this.events,
    required this.page,
    required this.pageSize,
    required this.hasMore,
  });

  final List<EventData> events;
  final int page;
  final int pageSize;
  final bool hasMore;

  int? get nextCursor =>
      events.isEmpty ? null : (page - 1) * pageSize + events.length - 1;

  @override
  String toString() => 'ChannelPage(page=$page, size=${events.length}, hasMore=$hasMore)';
}

String rangeHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List toUint8List(Object? raw) {
  if (raw is Uint8List) return raw;
  if (raw is List<int>) return Uint8List.fromList(raw);
  return Uint8List.fromList((raw as List).cast<int>());
}
