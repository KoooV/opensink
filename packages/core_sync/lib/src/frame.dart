import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_protocol/core_protocol.dart';

import 'errors.dart';
import 'sync_event.dart';

const int maxSyncFrameBytes = 1024 * 1024;
const int maxEventsPerFrame = 128;
const int maxRangesPerSummary = 4096;

/// Ширина HLC-бакета сводок. Одинакова на всех узлах протокола.
const int syncSummaryBucketMs = 60 * 1000;

/// Верхняя граница HLC для явного запроса всей истории (2^53-1).
const int maxSyncHlcPhysical = 9007199254740991;

/// Тип кадра синхронизации.
enum SyncFrameType {
  summary(1),
  rangeRequest(2),
  windowRequest(3),
  events(4),
  gossip(5),
  ping(6);

  const SyncFrameType(this.code);
  final int code;

  static SyncFrameType? fromCode(int code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

sealed class SyncFrame {
  const SyncFrame();
}

class RangeDigest {
  const RangeDigest({
    required this.fromHlc,
    required this.toHlc,
    required this.count,
    required this.hashHex,
  });

  final int fromHlc;
  final int toHlc;
  final int count;
  final String hashHex;

  @override
  String toString() =>
      'RangeDigest($fromHlc..$toHlc, count=$count, hash=$hashHex)';
}

class SummaryFrame extends SyncFrame {
  const SummaryFrame({required this.groupId, required this.ranges});
  final GroupId groupId;
  final List<RangeDigest> ranges;
}

class RangeRequestFrame extends SyncFrame {
  const RangeRequestFrame({
    required this.requestId,
    required this.groupId,
    required this.fromHlc,
    required this.toHlc,
    this.afterHlc,
    this.afterId,
    this.limit = 64,
    this.channelId,
  });

  final String requestId;
  final GroupId groupId;
  final int fromHlc;
  final int toHlc;
  final int? afterHlc;
  final String? afterId;
  final int limit;

  /// Ограничение диапазона одним каналом. `null` — вся группа.
  final ChannelId? channelId;
}

class WindowRequestFrame extends SyncFrame {
  const WindowRequestFrame({
    required this.requestId,
    required this.groupId,
    required this.channelId,
    this.limit = 50,
  });

  final String requestId;
  final GroupId groupId;
  final ChannelId channelId;
  final int limit;
}

class EventsFrame extends SyncFrame {
  const EventsFrame({
    required this.requestId,
    required this.groupId,
    required this.events,
    this.more = false,
    this.cursorHlc,
    this.cursorId,
  });

  final String requestId;
  final GroupId groupId;
  final List<SyncEvent> events;
  final bool more;
  final int? cursorHlc;
  final String? cursorId;
}

class GossipFrame extends SyncFrame {
  const GossipFrame({required this.events, this.hops = 0});

  final List<SyncEvent> events;
  final int hops;
}

class PingFrame extends SyncFrame {
  const PingFrame();
}

/// Protobuf-кодек кадров синхронизации.
class SyncFrameCodec {
  const SyncFrameCodec();

  static const SyncEventCodec _events = SyncEventCodec();

  Result<Uint8List, SyncError> encode(SyncFrame frame) {
    try {
      final writer = ProtoWriter();
      switch (frame) {
        case SummaryFrame():
          writer.writeVarintField(1, SyncFrameType.summary.code);
          writer.writeStringField(2, frame.groupId.value);
          for (final range in frame.ranges) {
            writer.writeBytesField(3, _encodeDigest(range));
          }
        case RangeRequestFrame():
          writer.writeVarintField(1, SyncFrameType.rangeRequest.code);
          writer.writeStringField(2, frame.requestId);
          writer.writeStringField(3, frame.groupId.value);
          writer.writeVarintField(4, frame.fromHlc);
          writer.writeVarintField(5, frame.toHlc);
          if (frame.afterHlc != null) {
            writer.writeVarintField(6, frame.afterHlc!);
          }
          if (frame.afterId != null) {
            writer.writeStringField(7, frame.afterId!);
          }
          writer.writeVarintField(8, frame.limit);
          if (frame.channelId != null) {
            writer.writeStringField(9, frame.channelId!.value);
          }
        case WindowRequestFrame():
          writer.writeVarintField(1, SyncFrameType.windowRequest.code);
          writer.writeStringField(2, frame.requestId);
          writer.writeStringField(3, frame.groupId.value);
          writer.writeStringField(4, frame.channelId.value);
          writer.writeVarintField(5, frame.limit);
        case EventsFrame():
          writer.writeVarintField(1, SyncFrameType.events.code);
          writer.writeStringField(2, frame.requestId);
          writer.writeStringField(3, frame.groupId.value);
          for (final event in frame.events) {
            final encoded = _events.encode(event);
            if (encoded.isErr) return Err(encoded.unwrapErr());
            writer.writeBytesField(4, encoded.unwrap());
          }
          if (frame.more) writer.writeVarintField(5, 1);
          if (frame.cursorHlc != null) {
            writer.writeVarintField(6, frame.cursorHlc!);
          }
          if (frame.cursorId != null) {
            writer.writeStringField(7, frame.cursorId!);
          }
        case GossipFrame():
          writer.writeVarintField(1, SyncFrameType.gossip.code);
          writer.writeVarintField(2, frame.hops);
          for (final event in frame.events) {
            final encoded = _events.encode(event);
            if (encoded.isErr) return Err(encoded.unwrapErr());
            writer.writeBytesField(3, encoded.unwrap());
          }
        case PingFrame():
          writer.writeVarintField(1, SyncFrameType.ping.code);
      }
      final bytes = writer.finish();
      if (bytes.length > maxSyncFrameBytes) {
        return Err(FrameTooLarge(bytes.length, maxSyncFrameBytes));
      }
      return Ok(bytes);
    } catch (error) {
      return Err(MalformedFrame(error.toString()));
    }
  }

  Result<SyncFrame, SyncError> decode(Uint8List bytes) {
    if (bytes.length > maxSyncFrameBytes) {
      return Err(FrameTooLarge(bytes.length, maxSyncFrameBytes));
    }
    try {
      final reader = ProtoReader(bytes);
      int? typeCode;
      String? groupId;
      String? requestId;
      String? channelId;
      var fromHlc = 0;
      var toHlc = 0;
      int? afterHlc;
      String? afterId;
      var limit = 0;
      final digests = <RangeDigest>[];
      final eventBytes = <Uint8List>[];
      final gossipBytes = <Uint8List>[];
      var more = false;
      int? cursorHlc;
      String? cursorId;
      var hops = 0;

      while (true) {
        final tag = reader.readTag();
        if (tag == null) break;
        final (field, wireType) = tag;
        switch (field) {
          case 1:
            typeCode = reader.readVarint();
          case 2:
            if (typeCode == SyncFrameType.gossip.code) {
              hops = reader.readVarint();
            } else {
              final value = reader.readStringField();
              requestId = value;
              if (typeCode == SyncFrameType.summary.code) groupId = value;
            }
          case 3:
            if (typeCode == SyncFrameType.summary.code) {
              if (digests.length >= maxRangesPerSummary) {
                return const Err(MalformedFrame('too many ranges'));
              }
              digests.add(_decodeDigest(reader.readBytes()));
            } else if (typeCode == SyncFrameType.rangeRequest.code) {
              groupId = reader.readStringField();
            } else if (typeCode == SyncFrameType.windowRequest.code) {
              groupId = reader.readStringField();
            } else if (typeCode == SyncFrameType.events.code) {
              groupId = reader.readStringField();
            } else if (typeCode == SyncFrameType.gossip.code) {
              if (gossipBytes.length >= maxEventsPerFrame) {
                return const Err(MalformedFrame('too many gossip events'));
              }
              gossipBytes.add(reader.readBytes());
            }
          case 4:
            if (typeCode == SyncFrameType.rangeRequest.code) {
              fromHlc = reader.readVarint();
            } else if (typeCode == SyncFrameType.windowRequest.code) {
              channelId = reader.readStringField();
            } else if (typeCode == SyncFrameType.events.code) {
              if (eventBytes.length >= maxEventsPerFrame) {
                return const Err(MalformedFrame('too many events in frame'));
              }
              eventBytes.add(reader.readBytes());
            }
          case 5:
            if (typeCode == SyncFrameType.rangeRequest.code) {
              toHlc = reader.readVarint();
            } else if (typeCode == SyncFrameType.windowRequest.code) {
              limit = reader.readVarint();
            } else if (typeCode == SyncFrameType.events.code) {
              more = reader.readVarint() != 0;
            }
          case 6:
            if (typeCode == SyncFrameType.rangeRequest.code) {
              afterHlc = reader.readVarint();
            } else if (typeCode == SyncFrameType.events.code) {
              cursorHlc = reader.readVarint();
            }
          case 7:
            if (typeCode == SyncFrameType.rangeRequest.code) {
              afterId = reader.readStringField();
            } else if (typeCode == SyncFrameType.events.code) {
              cursorId = reader.readStringField();
            }
          case 8:
            if (typeCode == SyncFrameType.rangeRequest.code) {
              limit = reader.readVarint();
            }
          case 9:
            if (typeCode == SyncFrameType.rangeRequest.code) {
              channelId = reader.readStringField();
            }
          default:
            reader.consumeField(wireType);
        }
      }

      if (typeCode == null) {
        return const Err(MalformedFrame('missing frame type'));
      }
      final type = SyncFrameType.fromCode(typeCode);
      if (type == null) return Err(UnsupportedFrame(typeCode));

      switch (type) {
        case SyncFrameType.summary:
          if (groupId == null || digests.length > maxRangesPerSummary) {
            return const Err(MalformedFrame('invalid summary'));
          }
          return Ok(SummaryFrame(groupId: GroupId(groupId), ranges: digests));
        case SyncFrameType.rangeRequest:
          if (requestId == null || groupId == null) {
            return const Err(MalformedFrame('invalid range request'));
          }
          return Ok(
            RangeRequestFrame(
              requestId: requestId,
              groupId: GroupId(groupId),
              fromHlc: fromHlc,
              toHlc: toHlc,
              afterHlc: afterHlc,
              afterId: afterId,
              limit: limit <= 0 ? 64 : limit,
              channelId: (channelId == null || channelId.isEmpty)
                  ? null
                  : ChannelId(channelId),
            ),
          );
        case SyncFrameType.windowRequest:
          if (requestId == null || groupId == null || channelId == null) {
            return const Err(MalformedFrame('invalid window request'));
          }
          return Ok(
            WindowRequestFrame(
              requestId: requestId,
              groupId: GroupId(groupId),
              channelId: ChannelId(channelId),
              limit: limit <= 0 ? 50 : limit,
            ),
          );
        case SyncFrameType.events:
          if (requestId == null || groupId == null) {
            return const Err(MalformedFrame('invalid events frame'));
          }
          if (eventBytes.length > maxEventsPerFrame) {
            return const Err(MalformedFrame('too many events in frame'));
          }
          final decoded = <SyncEvent>[];
          for (final bytes in eventBytes) {
            final event = _events.decode(bytes);
            if (event.isErr) return Err(event.unwrapErr());
            decoded.add(event.unwrap());
          }
          return Ok(
            EventsFrame(
              requestId: requestId,
              groupId: GroupId(groupId),
              events: decoded,
              more: more,
              cursorHlc: cursorHlc,
              cursorId: cursorId,
            ),
          );
        case SyncFrameType.gossip:
          if (gossipBytes.length > maxEventsPerFrame) {
            return const Err(MalformedFrame('too many gossip events'));
          }
          final decoded = <SyncEvent>[];
          for (final bytes in gossipBytes) {
            final event = _events.decode(bytes);
            if (event.isErr) return Err(event.unwrapErr());
            decoded.add(event.unwrap());
          }
          return Ok(GossipFrame(events: decoded, hops: hops));
        case SyncFrameType.ping:
          return const Ok(PingFrame());
      }
    } on ProtocolError catch (error) {
      return Err(MalformedFrame(error.toString()));
    } catch (error) {
      return Err(MalformedFrame(error.toString()));
    }
  }

  Uint8List _encodeDigest(RangeDigest digest) {
    final writer = ProtoWriter();
    writer.writeVarintField(1, digest.fromHlc);
    writer.writeVarintField(2, digest.toHlc);
    writer.writeVarintField(3, digest.count);
    writer.writeBytesField(4, _hexToBytes(digest.hashHex));
    return writer.finish();
  }

  RangeDigest _decodeDigest(Uint8List bytes) {
    final reader = ProtoReader(bytes);
    var from = 0;
    var to = 0;
    var count = 0;
    var hash = Uint8List(0);
    while (true) {
      final tag = reader.readTag();
      if (tag == null) break;
      final (field, wireType) = tag;
      switch (field) {
        case 1:
          from = reader.readVarint();
        case 2:
          to = reader.readVarint();
        case 3:
          count = reader.readVarint();
        case 4:
          hash = reader.readBytes();
        default:
          reader.consumeField(wireType);
      }
    }
    return RangeDigest(
      fromHlc: from,
      toHlc: to,
      count: count,
      hashHex: _bytesToHex(hash),
    );
  }
}

Uint8List _hexToBytes(String hex) {
  if (hex.isEmpty) return Uint8List(0);
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}
