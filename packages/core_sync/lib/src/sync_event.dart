import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_protocol/core_protocol.dart';
import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'hlc.dart';

const String eventIdDomain = 'opensink/sync/event-id/v1|';
const String eventSignatureDomain = 'opensink/sync/event-signature/v1|';
const int syncEventVersion = 1;
const int maxSyncEventBytes = 512 * 1024;

/// Тип события в синхронизируемом логе.
enum SyncEventKind {
  groupCreated(1),
  memberAdded(2),
  memberRemoved(3),
  channelCreated(4),
  channelDeleted(5),
  groupRenamed(6),
  ownerTransferred(7),
  messageCreated(8),
  messageEdited(9),
  messageDeleted(10),
  inviteIssued(11),
  memberJoined(12),
  memberApproved(13),
  roleSet(14),
  keyRotated(15);

  const SyncEventKind(this.code);
  final int code;

  static SyncEventKind? fromCode(int code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

/// Неизменяемое событие лога.
///
/// [id] — SHA-256 канонических байтов, [prevId] — предыдущее событие того же
/// автора в группе (хэш-цепочка). Подпись Ed25519 считается над
/// доменно-разделёнными каноническими байтами.
class SyncEvent {
  SyncEvent({
    required this.id,
    required this.groupId,
    required this.authorId,
    required this.hlc,
    required this.kind,
    this.channelId,
    this.targetId,
    this.prevId,
    Uint8List? payload,
    this.signature = '',
  }) : payload = payload ?? Uint8List(0);

  final EventId id;
  final GroupId groupId;
  final ChannelId? channelId;
  final UserId authorId;
  final Hlc hlc;
  final SyncEventKind kind;

  /// Для `messageEdited`/`messageDeleted` — id исходного сообщения.
  /// Для `memberAdded`/`memberRemoved` — id пользователя.
  /// Для `channelCreated`/`channelDeleted` — id канала.
  final String? targetId;
  final EventId? prevId;
  final Uint8List payload;
  final String signature;

  SyncEvent copyWith({
    EventId? id,
    GroupId? groupId,
    ChannelId? channelId,
    UserId? authorId,
    Hlc? hlc,
    SyncEventKind? kind,
    String? targetId,
    EventId? prevId,
    Uint8List? payload,
    String? signature,
  }) {
    return SyncEvent(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      channelId: channelId ?? this.channelId,
      authorId: authorId ?? this.authorId,
      hlc: hlc ?? this.hlc,
      kind: kind ?? this.kind,
      targetId: targetId ?? this.targetId,
      prevId: prevId ?? this.prevId,
      payload: payload ?? this.payload,
      signature: signature ?? this.signature,
    );
  }

  /// Канонические байты, не включающие id и подпись.
  Uint8List canonicalBytes() {
    final writer = ProtoWriter();
    writer.writeVarintField(1, syncEventVersion);
    writer.writeStringField(2, groupId.value);
    if (channelId != null) writer.writeStringField(3, channelId!.value);
    writer.writeStringField(4, authorId.value);
    writer.writeVarintField(5, hlc.physicalMs);
    writer.writeVarintField(6, hlc.counter);
    writer.writeVarintField(7, kind.code);
    if (targetId != null) writer.writeStringField(8, targetId!);
    if (prevId != null) writer.writeStringField(9, prevId!.value);
    writer.writeBytesField(10, payload);
    return writer.finish();
  }

  String computeId() {
    final digest = sha256.convert(<int>[
      ...utf8.encode(eventIdDomain),
      ...canonicalBytes(),
    ]);
    return digest.toString();
  }

  Uint8List signedBytes() {
    return Uint8List.fromList(<int>[
      ...utf8.encode(eventSignatureDomain),
      ...canonicalBytes(),
    ]);
  }

  EventRecord toRecord() => EventRecord(
    id: id.value,
    groupId: groupId,
    channelId: channelId,
    author: authorId.value,
    payload: canonicalBytes(),
    timestamp: hlc.physicalMs,
    signature: signature,
  );

  int compareTo(SyncEvent other) {
    final byHlc = hlc.compareTo(other.hlc);
    if (byHlc != 0) return byHlc;
    return id.value.compareTo(other.id.value);
  }

  @override
  String toString() =>
      'SyncEvent(id=${id.value}, group=${groupId.value}, kind=$kind, hlc=$hlc)';
}

/// Кодек одного события. Каноническое представление детерминировано,
/// потому что поля пишутся в фиксированном порядке.
class SyncEventCodec {
  const SyncEventCodec();

  Result<Uint8List, SyncError> encode(SyncEvent event) {
    final canonical = event.canonicalBytes();
    if (canonical.length > maxSyncEventBytes) {
      return Err(EventTooLarge(canonical.length, maxSyncEventBytes));
    }
    final writer = ProtoWriter();
    writer.writeBytesField(1, canonical);
    writer.writeStringField(2, event.id.value);
    writer.writeStringField(3, event.signature);
    final encoded = writer.finish();
    if (encoded.length > maxSyncEventBytes + 1024) {
      return Err(EventTooLarge(encoded.length, maxSyncEventBytes));
    }
    return Ok(encoded);
  }

  Result<SyncEvent, SyncError> decode(Uint8List bytes) {
    if (bytes.length > maxSyncEventBytes + 1024) {
      return Err(EventTooLarge(bytes.length, maxSyncEventBytes));
    }
    try {
      final reader = ProtoReader(bytes);
      Uint8List? canonical;
      String id = '';
      String signature = '';
      while (true) {
        final tag = reader.readTag();
        if (tag == null) break;
        final (field, wireType) = tag;
        switch (field) {
          case 1:
            canonical = reader.readBytes();
          case 2:
            id = reader.readStringField();
          case 3:
            signature = reader.readStringField();
          default:
            reader.consumeField(wireType);
        }
      }
      if (canonical == null || canonical.isEmpty) {
        return const Err(MalformedEvent('missing canonical body'));
      }
      return decodeCanonical(canonical, eventId: id, signature: signature);
    } on ProtocolError catch (error) {
      return Err(MalformedEvent(error.toString()));
    } catch (error) {
      return Err(MalformedEvent(error.toString()));
    }
  }

  Result<SyncEvent, SyncError> decodeCanonical(
    Uint8List canonical, {
    required String eventId,
    required String signature,
  }) {
    if (canonical.length > maxSyncEventBytes) {
      return Err(EventTooLarge(canonical.length, maxSyncEventBytes));
    }
    try {
      final reader = ProtoReader(canonical);
      var version = 0;
      var groupId = '';
      String? channelId;
      var authorId = '';
      var physicalMs = 0;
      var counter = 0;
      int? kindCode;
      String? targetId;
      String? prevId;
      var payload = Uint8List(0);

      while (true) {
        final tag = reader.readTag();
        if (tag == null) break;
        final (field, wireType) = tag;
        switch (field) {
          case 1:
            version = reader.readVarint();
          case 2:
            groupId = reader.readStringField();
          case 3:
            channelId = reader.readStringField();
          case 4:
            authorId = reader.readStringField();
          case 5:
            physicalMs = reader.readVarint();
          case 6:
            counter = reader.readVarint();
          case 7:
            kindCode = reader.readVarint();
          case 8:
            targetId = reader.readStringField();
          case 9:
            prevId = reader.readStringField();
          case 10:
            payload = reader.readBytes();
          default:
            reader.consumeField(wireType);
        }
      }

      if (version != syncEventVersion) {
        return Err(MalformedEvent('unsupported event version $version'));
      }
      if (groupId.isEmpty || authorId.isEmpty || kindCode == null) {
        return const Err(MalformedEvent('missing required event fields'));
      }
      final kind = SyncEventKind.fromCode(kindCode);
      if (kind == null) {
        return Err(MalformedEvent('unknown event kind $kindCode'));
      }
      if (channelId != null && channelId.isEmpty) channelId = null;

      final event = SyncEvent(
        id: EventId(eventId),
        groupId: GroupId(groupId),
        channelId: channelId == null ? null : ChannelId(channelId),
        authorId: UserId(authorId),
        hlc: Hlc(physicalMs, counter),
        kind: kind,
        targetId: (targetId == null || targetId.isEmpty) ? null : targetId,
        prevId: (prevId == null || prevId.isEmpty) ? null : EventId(prevId),
        payload: payload,
        signature: signature,
      );
      final computed = event.computeId();
      if (eventId.isNotEmpty && eventId != computed) {
        return Err(EventIdMismatch(eventId, computed));
      }
      if (eventId.isEmpty) {
        return Ok(event.copyWith(id: EventId(computed)));
      }
      return Ok(event);
    } on ProtocolError catch (error) {
      return Err(MalformedEvent(error.toString()));
    } catch (error) {
      return Err(MalformedEvent(error.toString()));
    }
  }

  Result<SyncEvent, SyncError> fromRecord(EventRecord record) {
    final decoded = decodeCanonical(
      Uint8List.fromList(record.payload),
      eventId: record.id,
      signature: record.signature,
    );
    if (decoded.isErr) return decoded;
    final event = decoded.unwrap();
    if (event.groupId.value != record.groupId.value) {
      return const Err(MalformedEvent('group id does not match record'));
    }
    if (event.authorId.value != record.author) {
      return const Err(MalformedEvent('author does not match record'));
    }
    if (event.hlc.physicalMs != record.timestamp) {
      return const Err(MalformedEvent('hlc does not match record'));
    }
    if (event.channelId?.value != record.channelId?.value) {
      return const Err(MalformedEvent('channel does not match record'));
    }
    return Ok(event);
  }
}
