import 'dart:typed_data';

import 'wire.dart';

/// ChatEvent — текстовое сообщение в канале.
class ChatEvent {
  ChatEvent({
    required this.id,
    required this.groupId,
    required this.channelId,
    required this.authorId,
    required this.timestamp,
    this.text = '',
    this.replyTo = '',
    this.attachments = const <Uint8List>[],
    this._unknownFields = const <int, Uint8List>{},
  });

  final String id;
  final String groupId;
  final String channelId;
  final String authorId;
  final int timestamp; // Unix ms
  final String text;
  final String replyTo;
  final List<Uint8List> attachments; // ссылки на чанки файла
  final Map<int, Uint8List> _unknownFields;

  ChatEvent copyWith({
    String? id,
    String? groupId,
    String? channelId,
    String? authorId,
    int? timestamp,
    String? text,
    String? replyTo,
    List<Uint8List>? attachments,
    Map<int, Uint8List>? unknownFields,
  }) {
    return ChatEvent(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      channelId: channelId ?? this.channelId,
      authorId: authorId ?? this.authorId,
      timestamp: timestamp ?? this.timestamp,
      text: text ?? this.text,
      replyTo: replyTo ?? this.replyTo,
      attachments: attachments ?? this.attachments,
      unknownFields: unknownFields ?? this._unknownFields,
    );
  }

  void writeTo(ProtoWriter writer) {
    writer.writeStringField(1, id);
    writer.writeStringField(2, groupId);
    writer.writeStringField(3, channelId);
    writer.writeStringField(4, authorId);
    writer.writeVarintField(5, timestamp);
    if (text.isNotEmpty) {
      writer.writeStringField(6, text);
    }
    if (replyTo.isNotEmpty) {
      writer.writeStringField(7, replyTo);
    }
    for (final attachment in attachments) {
      writer.writeBytesField(8, attachment);
    }
    writer.writeUnknownFields(_unknownFields);
  }

  Uint8List toBytes() {
    final writer = ProtoWriter();
    writeTo(writer);
    return writer.finish();
  }

  static ChatEvent fromBytes(Uint8List bytes) {
    return fromReader(ProtoReader(bytes));
  }

  static ChatEvent fromReader(ProtoReader reader) {
    String id = '';
    String groupId = '';
    String channelId = '';
    String authorId = '';
    int timestamp = 0;
    String text = '';
    String replyTo = '';
    final attachments = <Uint8List>[];
    final unknown = <int, Uint8List>{};

    while (true) {
      final start = reader.mark();
      final tag = reader.readTag();
      if (tag == null) break;
      final (fieldNumber, wireType) = tag;
      switch (fieldNumber) {
        case 1:
          id = reader.readStringField();
          break;
        case 2:
          groupId = reader.readStringField();
          break;
        case 3:
          channelId = reader.readStringField();
          break;
        case 4:
          authorId = reader.readStringField();
          break;
        case 5:
          timestamp = reader.readVarint();
          break;
        case 6:
          text = reader.readStringField();
          break;
        case 7:
          replyTo = reader.readStringField();
          break;
        case 8:
          attachments.add(reader.readBytes());
          break;
        default:
          reader.consumeField(wireType);
          unknown[fieldNumber] = reader.slice(start, reader.position);
          break;
      }
    }

    return ChatEvent(
      id: id,
      groupId: groupId,
      channelId: channelId,
      authorId: authorId,
      timestamp: timestamp,
      text: text,
      replyTo: replyTo,
      attachments: attachments,
      unknownFields: unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatEvent &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          groupId == other.groupId &&
          channelId == other.channelId &&
          authorId == other.authorId &&
          timestamp == other.timestamp &&
          text == other.text &&
          replyTo == other.replyTo &&
          _bytesListEquals(attachments, other.attachments) &&
          _mapEquals(_unknownFields, other._unknownFields);

  @override
  int get hashCode {
    var result = id.hashCode;
    result ^= groupId.hashCode;
    result ^= channelId.hashCode;
    result ^= authorId.hashCode;
    result ^= timestamp.hashCode;
    result ^= text.hashCode;
    result ^= replyTo.hashCode;
    result ^= _bytesListHash(attachments);
    result ^= _unknownFields.hashCode;
    return result;
  }

  @override
  String toString() => 'ChatEvent(id=$id, groupId=$groupId, channelId=$channelId)';
}

/// GroupEvent — событие, влияющее на состояние группы (плоская структура).
class GroupEvent {
  GroupEvent({
    required this.id,
    required this.groupId,
    required this.authorId,
    required this.timestamp,
    this.signature = '',
    required this.eventType,
    this.name = '',
    this.ownerId = '',
    this.initialMembers = const <String>[],
    this.userId = '',
    this.channelId = '',
    this.channelType = '',
    this.newOwnerId = '',
    this._unknownFields = const <int, Uint8List>{},
  });

  final String id;
  final String groupId;
  final String authorId;
  final int timestamp; // Unix ms
  final String signature; // hex Ed25519
  final int eventType; // 1 group_created ... 7 owner_transferred
  final String name;
  final String ownerId;
  final List<String> initialMembers;
  final String userId;
  final String channelId;
  final String channelType;
  final String newOwnerId;
  final Map<int, Uint8List> _unknownFields;

  GroupEvent copyWith({
    String? id,
    String? groupId,
    String? authorId,
    int? timestamp,
    String? signature,
    int? eventType,
    String? name,
    String? ownerId,
    List<String>? initialMembers,
    String? userId,
    String? channelId,
    String? channelType,
    String? newOwnerId,
    Map<int, Uint8List>? unknownFields,
  }) {
    return GroupEvent(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      authorId: authorId ?? this.authorId,
      timestamp: timestamp ?? this.timestamp,
      signature: signature ?? this.signature,
      eventType: eventType ?? this.eventType,
      name: name ?? this.name,
      ownerId: ownerId ?? this.ownerId,
      initialMembers: initialMembers ?? this.initialMembers,
      userId: userId ?? this.userId,
      channelId: channelId ?? this.channelId,
      channelType: channelType ?? this.channelType,
      newOwnerId: newOwnerId ?? this.newOwnerId,
      unknownFields: unknownFields ?? this._unknownFields,
    );
  }

  void writeTo(ProtoWriter writer) {
    writer.writeStringField(1, id);
    writer.writeStringField(2, groupId);
    writer.writeStringField(3, authorId);
    writer.writeVarintField(4, timestamp);
    if (signature.isNotEmpty) {
      writer.writeStringField(5, signature);
    }
    writer.writeVarintField(6, eventType);
    if (name.isNotEmpty) {
      writer.writeStringField(7, name);
    }
    if (ownerId.isNotEmpty) {
      writer.writeStringField(8, ownerId);
    }
    for (final member in initialMembers) {
      writer.writeStringField(9, member);
    }
    if (userId.isNotEmpty) {
      writer.writeStringField(10, userId);
    }
    if (channelId.isNotEmpty) {
      writer.writeStringField(11, channelId);
    }
    if (channelType.isNotEmpty) {
      writer.writeStringField(12, channelType);
    }
    if (newOwnerId.isNotEmpty) {
      writer.writeStringField(13, newOwnerId);
    }
    writer.writeUnknownFields(_unknownFields);
  }

  Uint8List toBytes() {
    final writer = ProtoWriter();
    writeTo(writer);
    return writer.finish();
  }

  static GroupEvent fromBytes(Uint8List bytes) {
    return fromReader(ProtoReader(bytes));
  }

  static GroupEvent fromReader(ProtoReader reader) {
    String id = '';
    String groupId = '';
    String authorId = '';
    int timestamp = 0;
    String signature = '';
    int eventType = 0;
    String name = '';
    String ownerId = '';
    final initialMembers = <String>[];
    String userId = '';
    String channelId = '';
    String channelType = '';
    String newOwnerId = '';
    final unknown = <int, Uint8List>{};

    while (true) {
      final start = reader.mark();
      final tag = reader.readTag();
      if (tag == null) break;
      final (fieldNumber, wireType) = tag;
      switch (fieldNumber) {
        case 1:
          id = reader.readStringField();
          break;
        case 2:
          groupId = reader.readStringField();
          break;
        case 3:
          authorId = reader.readStringField();
          break;
        case 4:
          timestamp = reader.readVarint();
          break;
        case 5:
          signature = reader.readStringField();
          break;
        case 6:
          eventType = reader.readVarint();
          break;
        case 7:
          name = reader.readStringField();
          break;
        case 8:
          ownerId = reader.readStringField();
          break;
        case 9:
          initialMembers.add(reader.readStringField());
          break;
        case 10:
          userId = reader.readStringField();
          break;
        case 11:
          channelId = reader.readStringField();
          break;
        case 12:
          channelType = reader.readStringField();
          break;
        case 13:
          newOwnerId = reader.readStringField();
          break;
        default:
          reader.consumeField(wireType);
          unknown[fieldNumber] = reader.slice(start, reader.position);
          break;
      }
    }

    return GroupEvent(
      id: id,
      groupId: groupId,
      authorId: authorId,
      timestamp: timestamp,
      signature: signature,
      eventType: eventType,
      name: name,
      ownerId: ownerId,
      initialMembers: initialMembers,
      userId: userId,
      channelId: channelId,
      channelType: channelType,
      newOwnerId: newOwnerId,
      unknownFields: unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupEvent &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          groupId == other.groupId &&
          authorId == other.authorId &&
          timestamp == other.timestamp &&
          signature == other.signature &&
          eventType == other.eventType &&
          name == other.name &&
          ownerId == other.ownerId &&
          _stringListEquals(initialMembers, other.initialMembers) &&
          userId == other.userId &&
          channelId == other.channelId &&
          channelType == other.channelType &&
          newOwnerId == other.newOwnerId &&
          _mapEquals(_unknownFields, other._unknownFields);

  @override
  int get hashCode {
    var result = id.hashCode;
    result ^= groupId.hashCode;
    result ^= authorId.hashCode;
    result ^= timestamp.hashCode;
    result ^= signature.hashCode;
    result ^= eventType.hashCode;
    result ^= name.hashCode;
    result ^= ownerId.hashCode;
    result ^= _stringListHash(initialMembers);
    result ^= userId.hashCode;
    result ^= channelId.hashCode;
    result ^= channelType.hashCode;
    result ^= newOwnerId.hashCode;
    result ^= _unknownFields.hashCode;
    return result;
  }

  @override
  String toString() => 'GroupEvent(id=$id, groupId=$groupId, eventType=$eventType)';
}

/// SyncRequest — запрос синхронизации событий с узла.
class SyncRequest {
  SyncRequest({
    required this.requester,
    this.sinceEventId = '',
    this.sinceHlc = 0,
    this.limit = 100,
    this.groupIds = const <String>[],
    this._unknownFields = const <int, Uint8List>{},
  });

  final String requester; // hex peer id
  final String sinceEventId;
  final int sinceHlc;
  final int limit;
  final List<String> groupIds;
  final Map<int, Uint8List> _unknownFields;

  void writeTo(ProtoWriter writer) {
    writer.writeStringField(1, requester);
    if (sinceEventId.isNotEmpty) {
      writer.writeStringField(2, sinceEventId);
    }
    if (sinceHlc != 0) {
      writer.writeVarintField(3, sinceHlc);
    }
    if (limit != 100) {
      writer.writeVarintField(4, limit);
    }
    for (final groupId in groupIds) {
      writer.writeStringField(5, groupId);
    }
    writer.writeUnknownFields(_unknownFields);
  }

  Uint8List toBytes() {
    final writer = ProtoWriter();
    writeTo(writer);
    return writer.finish();
  }

  static SyncRequest fromBytes(Uint8List bytes) {
    return fromReader(ProtoReader(bytes));
  }

  static SyncRequest fromReader(ProtoReader reader) {
    String requester = '';
    String sinceEventId = '';
    int sinceHlc = 0;
    int limit = 100;
    final groupIds = <String>[];
    final unknown = <int, Uint8List>{};

    while (true) {
      final start = reader.mark();
      final tag = reader.readTag();
      if (tag == null) break;
      final (fieldNumber, wireType) = tag;
      switch (fieldNumber) {
        case 1:
          requester = reader.readStringField();
          break;
        case 2:
          sinceEventId = reader.readStringField();
          break;
        case 3:
          sinceHlc = reader.readVarint();
          break;
        case 4:
          limit = reader.readVarint();
          break;
        case 5:
          groupIds.add(reader.readStringField());
          break;
        default:
          reader.consumeField(wireType);
          unknown[fieldNumber] = reader.slice(start, reader.position);
          break;
      }
    }

    return SyncRequest(
      requester: requester,
      sinceEventId: sinceEventId,
      sinceHlc: sinceHlc,
      limit: limit,
      groupIds: groupIds,
      unknownFields: unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncRequest &&
          runtimeType == other.runtimeType &&
          requester == other.requester &&
          sinceEventId == other.sinceEventId &&
          sinceHlc == other.sinceHlc &&
          limit == other.limit &&
          _stringListEquals(groupIds, other.groupIds) &&
          _mapEquals(_unknownFields, other._unknownFields);

  @override
  int get hashCode {
    var result = requester.hashCode;
    result ^= sinceEventId.hashCode;
    result ^= sinceHlc.hashCode;
    result ^= limit.hashCode;
    result ^= _stringListHash(groupIds);
    result ^= _unknownFields.hashCode;
    return result;
  }

  @override
  String toString() => 'SyncRequest(requester=$requester, limit=$limit)';
}

/// SyncResponse — ответ синхронизации.
class SyncResponse {
  SyncResponse({
    required this.responder,
    this.events = const <Uint8List>[],
    this.checkpoint = '',
    this.more = false,
    this._unknownFields = const <int, Uint8List>{},
  });

  final String responder; // hex peer id
  final List<Uint8List> events; // сериализованные Envelope
  final String checkpoint;
  final bool more;
  final Map<int, Uint8List> _unknownFields;

  void writeTo(ProtoWriter writer) {
    writer.writeStringField(1, responder);
    for (final event in events) {
      writer.writeBytesField(2, event);
    }
    if (checkpoint.isNotEmpty) {
      writer.writeStringField(3, checkpoint);
    }
    if (more) {
      writer.writeVarintField(4, more ? 1 : 0);
    }
    writer.writeUnknownFields(_unknownFields);
  }

  Uint8List toBytes() {
    final writer = ProtoWriter();
    writeTo(writer);
    return writer.finish();
  }

  static SyncResponse fromBytes(Uint8List bytes) {
    return fromReader(ProtoReader(bytes));
  }

  static SyncResponse fromReader(ProtoReader reader) {
    String responder = '';
    final events = <Uint8List>[];
    String checkpoint = '';
    bool more = false;
    final unknown = <int, Uint8List>{};

    while (true) {
      final start = reader.mark();
      final tag = reader.readTag();
      if (tag == null) break;
      final (fieldNumber, wireType) = tag;
      switch (fieldNumber) {
        case 1:
          responder = reader.readStringField();
          break;
        case 2:
          events.add(reader.readBytes());
          break;
        case 3:
          checkpoint = reader.readStringField();
          break;
        case 4:
          more = reader.readVarint() != 0;
          break;
        default:
          reader.consumeField(wireType);
          unknown[fieldNumber] = reader.slice(start, reader.position);
          break;
      }
    }

    return SyncResponse(
      responder: responder,
      events: events,
      checkpoint: checkpoint,
      more: more,
      unknownFields: unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncResponse &&
          runtimeType == other.runtimeType &&
          responder == other.responder &&
          _bytesListEquals(events, other.events) &&
          checkpoint == other.checkpoint &&
          more == other.more &&
          _mapEquals(_unknownFields, other._unknownFields);

  @override
  int get hashCode {
    var result = responder.hashCode;
    result ^= _bytesListHash(events);
    result ^= checkpoint.hashCode;
    result ^= more.hashCode;
    result ^= _unknownFields.hashCode;
    return result;
  }

  @override
  String toString() => 'SyncResponse(responder=$responder, events=${events.length})';
}

/// FileChunk — фрагмент файла для чанковой передачи.
class FileChunk {
  FileChunk({
    required this.fileId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.data,
    required this.totalSize,
    required this.sha256,
    required this.chunkHash,
    this._unknownFields = const <int, Uint8List>{},
  });

  final String fileId;
  final int chunkIndex;
  final int totalChunks;
  final Uint8List data;
  final int totalSize;
  final Uint8List sha256; // хеш всего файла
  final Uint8List chunkHash; // хеш чанка
  final Map<int, Uint8List> _unknownFields;

  void writeTo(ProtoWriter writer) {
    writer.writeStringField(1, fileId);
    writer.writeVarintField(2, chunkIndex);
    writer.writeVarintField(3, totalChunks);
    if (data.isNotEmpty) {
      writer.writeBytesField(4, data);
    }
    writer.writeVarintField(5, totalSize);
    if (sha256.isNotEmpty) {
      writer.writeBytesField(6, sha256);
    }
    if (chunkHash.isNotEmpty) {
      writer.writeBytesField(7, chunkHash);
    }
    writer.writeUnknownFields(_unknownFields);
  }

  Uint8List toBytes() {
    final writer = ProtoWriter();
    writeTo(writer);
    return writer.finish();
  }

  static FileChunk fromBytes(Uint8List bytes) {
    return fromReader(ProtoReader(bytes));
  }

  static FileChunk fromReader(ProtoReader reader) {
    String fileId = '';
    int chunkIndex = 0;
    int totalChunks = 0;
    final data = <int>[];
    int totalSize = 0;
    final sha256 = <int>[];
    final chunkHash = <int>[];
    final unknown = <int, Uint8List>{};

    while (true) {
      final start = reader.mark();
      final tag = reader.readTag();
      if (tag == null) break;
      final (fieldNumber, wireType) = tag;
      switch (fieldNumber) {
        case 1:
          fileId = reader.readStringField();
          break;
        case 2:
          chunkIndex = reader.readVarint();
          break;
        case 3:
          totalChunks = reader.readVarint();
          break;
        case 4:
          reader.readBytes().forEach(data.add);
          break;
        case 5:
          totalSize = reader.readVarint();
          break;
        case 6:
          reader.readBytes().forEach(sha256.add);
          break;
        case 7:
          reader.readBytes().forEach(chunkHash.add);
          break;
        default:
          reader.consumeField(wireType);
          unknown[fieldNumber] = reader.slice(start, reader.position);
          break;
      }
    }

    return FileChunk(
      fileId: fileId,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      data: Uint8List.fromList(data),
      totalSize: totalSize,
      sha256: Uint8List.fromList(sha256),
      chunkHash: Uint8List.fromList(chunkHash),
      unknownFields: unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileChunk &&
          runtimeType == other.runtimeType &&
          fileId == other.fileId &&
          chunkIndex == other.chunkIndex &&
          totalChunks == other.totalChunks &&
          _bytesEquals(data, other.data) &&
          totalSize == other.totalSize &&
          _bytesEquals(sha256, other.sha256) &&
          _bytesEquals(chunkHash, other.chunkHash) &&
          _mapEquals(_unknownFields, other._unknownFields);

  @override
  int get hashCode {
    var result = fileId.hashCode;
    result ^= chunkIndex.hashCode;
    result ^= totalChunks.hashCode;
    result ^= _bytesHash(data);
    result ^= totalSize.hashCode;
    result ^= _bytesHash(sha256);
    result ^= _bytesHash(chunkHash);
    result ^= _unknownFields.hashCode;
    return result;
  }

  @override
  String toString() => 'FileChunk(fileId=$fileId, chunkIndex=$chunkIndex/$totalChunks)';
}

/// FileRequest — запрос чанка файла.
class FileRequest {
  FileRequest({
    required this.fileId,
    required this.chunkIndex,
    required this.size,
    this._unknownFields = const <int, Uint8List>{},
  });

  final String fileId;
  final int chunkIndex;
  final int size;
  final Map<int, Uint8List> _unknownFields;

  void writeTo(ProtoWriter writer) {
    writer.writeStringField(1, fileId);
    writer.writeVarintField(2, chunkIndex);
    writer.writeVarintField(3, size);
    writer.writeUnknownFields(_unknownFields);
  }

  Uint8List toBytes() {
    final writer = ProtoWriter();
    writeTo(writer);
    return writer.finish();
  }

  static FileRequest fromBytes(Uint8List bytes) {
    return fromReader(ProtoReader(bytes));
  }

  static FileRequest fromReader(ProtoReader reader) {
    String fileId = '';
    int chunkIndex = 0;
    int size = 0;
    final unknown = <int, Uint8List>{};

    while (true) {
      final start = reader.mark();
      final tag = reader.readTag();
      if (tag == null) break;
      final (fieldNumber, wireType) = tag;
      switch (fieldNumber) {
        case 1:
          fileId = reader.readStringField();
          break;
        case 2:
          chunkIndex = reader.readVarint();
          break;
        case 3:
          size = reader.readVarint();
          break;
        default:
          reader.consumeField(wireType);
          unknown[fieldNumber] = reader.slice(start, reader.position);
          break;
      }
    }

    return FileRequest(
      fileId: fileId,
      chunkIndex: chunkIndex,
      size: size,
      unknownFields: unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileRequest &&
          runtimeType == other.runtimeType &&
          fileId == other.fileId &&
          chunkIndex == other.chunkIndex &&
          size == other.size &&
          _mapEquals(_unknownFields, other._unknownFields);

  @override
  int get hashCode {
    var result = fileId.hashCode;
    result ^= chunkIndex.hashCode;
    result ^= size.hashCode;
    result ^= _unknownFields.hashCode;
    return result;
  }

  @override
  String toString() => 'FileRequest(fileId=$fileId, chunkIndex=$chunkIndex)';
}

/// Presence — статус присутствия узла.
class Presence {
  Presence({
    required this.peerId,
    this.status = 'online',
    this.lastSeen = 0,
    this.capabilities = const <String>[],
    this._unknownFields = const <int, Uint8List>{},
  });

  final String peerId; // hex peer id
  final String status;
  final int lastSeen; // Unix ms
  final List<String> capabilities;
  final Map<int, Uint8List> _unknownFields;

  void writeTo(ProtoWriter writer) {
    writer.writeStringField(1, peerId);
    if (status.isNotEmpty) {
      writer.writeStringField(2, status);
    }
    if (lastSeen != 0) {
      writer.writeVarintField(3, lastSeen);
    }
    for (final capability in capabilities) {
      writer.writeStringField(4, capability);
    }
    writer.writeUnknownFields(_unknownFields);
  }

  Uint8List toBytes() {
    final writer = ProtoWriter();
    writeTo(writer);
    return writer.finish();
  }

  static Presence fromBytes(Uint8List bytes) {
    return fromReader(ProtoReader(bytes));
  }

  static Presence fromReader(ProtoReader reader) {
    String peerId = '';
    String status = 'online';
    int lastSeen = 0;
    final capabilities = <String>[];
    final unknown = <int, Uint8List>{};

    while (true) {
      final start = reader.mark();
      final tag = reader.readTag();
      if (tag == null) break;
      final (fieldNumber, wireType) = tag;
      switch (fieldNumber) {
        case 1:
          peerId = reader.readStringField();
          break;
        case 2:
          status = reader.readStringField();
          break;
        case 3:
          lastSeen = reader.readVarint();
          break;
        case 4:
          capabilities.add(reader.readStringField());
          break;
        default:
          reader.consumeField(wireType);
          unknown[fieldNumber] = reader.slice(start, reader.position);
          break;
      }
    }

    return Presence(
      peerId: peerId,
      status: status,
      lastSeen: lastSeen,
      capabilities: capabilities,
      unknownFields: unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Presence &&
          runtimeType == other.runtimeType &&
          peerId == other.peerId &&
          status == other.status &&
          lastSeen == other.lastSeen &&
          _stringListEquals(capabilities, other.capabilities) &&
          _mapEquals(_unknownFields, other._unknownFields);

  @override
  int get hashCode {
    var result = peerId.hashCode;
    result ^= status.hashCode;
    result ^= lastSeen.hashCode;
    result ^= _stringListHash(capabilities);
    result ^= _unknownFields.hashCode;
    return result;
  }

  @override
  String toString() => 'Presence(peerId=$peerId, status=$status)';
}

/// Тип вызова CallControl.
class CallControlType {
  const CallControlType._(this.value);
  final int value;

  static const unknown = CallControlType._(0);
  static const offer = CallControlType._(1);
  static const answer = CallControlType._(2);
  static const iceCandidate = CallControlType._(3);
  static const hangup = CallControlType._(4);

  static CallControlType fromInt(int value) {
    switch (value) {
      case 0:
        return unknown;
      case 1:
        return offer;
      case 2:
        return answer;
      case 3:
        return iceCandidate;
      case 4:
        return hangup;
      default:
        return CallControlType._(value);
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CallControlType && runtimeType == other.runtimeType && value == other.value;

  @override
  int get hashCode => value.hashCode;
}

/// CallControl — сигнализация вызова (WebRTC offer/answer/ICE/hangup).
class CallControl {
  CallControl({
    required this.callId,
    required this.callType,
    this.sdp = '',
    this.candidate = '',
    this.sdpMid = '',
    this.sdpMLineIndex = 0,
    this._unknownFields = const <int, Uint8List>{},
  });

  final String callId;
  final CallControlType callType;
  final String sdp;
  final String candidate;
  final String sdpMid;
  final int sdpMLineIndex;
  final Map<int, Uint8List> _unknownFields;

  void writeTo(ProtoWriter writer) {
    writer.writeStringField(1, callId);
    writer.writeVarintField(2, callType.value);
    if (sdp.isNotEmpty) {
      writer.writeStringField(3, sdp);
    }
    if (candidate.isNotEmpty) {
      writer.writeStringField(4, candidate);
    }
    if (sdpMid.isNotEmpty) {
      writer.writeStringField(5, sdpMid);
    }
    if (sdpMLineIndex != 0) {
      writer.writeVarintField(6, sdpMLineIndex);
    }
    writer.writeUnknownFields(_unknownFields);
  }

  Uint8List toBytes() {
    final writer = ProtoWriter();
    writeTo(writer);
    return writer.finish();
  }

  static CallControl fromBytes(Uint8List bytes) {
    return fromReader(ProtoReader(bytes));
  }

  static CallControl fromReader(ProtoReader reader) {
    String callId = '';
    int callTypeValue = 0;
    String sdp = '';
    String candidate = '';
    String sdpMid = '';
    int sdpMLineIndex = 0;
    final unknown = <int, Uint8List>{};

    while (true) {
      final start = reader.mark();
      final tag = reader.readTag();
      if (tag == null) break;
      final (fieldNumber, wireType) = tag;
      switch (fieldNumber) {
        case 1:
          callId = reader.readStringField();
          break;
        case 2:
          callTypeValue = reader.readVarint();
          break;
        case 3:
          sdp = reader.readStringField();
          break;
        case 4:
          candidate = reader.readStringField();
          break;
        case 5:
          sdpMid = reader.readStringField();
          break;
        case 6:
          sdpMLineIndex = reader.readVarint();
          break;
        default:
          reader.consumeField(wireType);
          unknown[fieldNumber] = reader.slice(start, reader.position);
          break;
      }
    }

    return CallControl(
      callId: callId,
      callType: CallControlType.fromInt(callTypeValue),
      sdp: sdp,
      candidate: candidate,
      sdpMid: sdpMid,
      sdpMLineIndex: sdpMLineIndex,
      unknownFields: unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CallControl &&
          runtimeType == other.runtimeType &&
          callId == other.callId &&
          callType == other.callType &&
          sdp == other.sdp &&
          candidate == other.candidate &&
          sdpMid == other.sdpMid &&
          sdpMLineIndex == other.sdpMLineIndex &&
          _mapEquals(_unknownFields, other._unknownFields);

  @override
  int get hashCode {
    var result = callId.hashCode;
    result ^= callType.hashCode;
    result ^= sdp.hashCode;
    result ^= candidate.hashCode;
    result ^= sdpMid.hashCode;
    result ^= sdpMLineIndex.hashCode;
    result ^= _unknownFields.hashCode;
    return result;
  }

  @override
  String toString() => 'CallControl(callId=$callId, type=$callType)';
}

/// LeaderLease — аренда лидера группы для консенсуса порядка событий.
class LeaderLease {
  LeaderLease({
    required this.groupId,
    required this.leaderId,
    required this.term,
    required this.expiresAt,
    required this.sequence,
    this._unknownFields = const <int, Uint8List>{},
  });

  final String groupId;
  final String leaderId; // hex peer id
  final int term;
  final int expiresAt; // Unix ms
  final int sequence;
  final Map<int, Uint8List> _unknownFields;

  void writeTo(ProtoWriter writer) {
    writer.writeStringField(1, groupId);
    writer.writeStringField(2, leaderId);
    writer.writeVarintField(3, term);
    writer.writeVarintField(4, expiresAt);
    writer.writeVarintField(5, sequence);
    writer.writeUnknownFields(_unknownFields);
  }

  Uint8List toBytes() {
    final writer = ProtoWriter();
    writeTo(writer);
    return writer.finish();
  }

  static LeaderLease fromBytes(Uint8List bytes) {
    return fromReader(ProtoReader(bytes));
  }

  static LeaderLease fromReader(ProtoReader reader) {
    String groupId = '';
    String leaderId = '';
    int term = 0;
    int expiresAt = 0;
    int sequence = 0;
    final unknown = <int, Uint8List>{};

    while (true) {
      final start = reader.mark();
      final tag = reader.readTag();
      if (tag == null) break;
      final (fieldNumber, wireType) = tag;
      switch (fieldNumber) {
        case 1:
          groupId = reader.readStringField();
          break;
        case 2:
          leaderId = reader.readStringField();
          break;
        case 3:
          term = reader.readVarint();
          break;
        case 4:
          expiresAt = reader.readVarint();
          break;
        case 5:
          sequence = reader.readVarint();
          break;
        default:
          reader.consumeField(wireType);
          unknown[fieldNumber] = reader.slice(start, reader.position);
          break;
      }
    }

    return LeaderLease(
      groupId: groupId,
      leaderId: leaderId,
      term: term,
      expiresAt: expiresAt,
      sequence: sequence,
      unknownFields: unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LeaderLease &&
          runtimeType == other.runtimeType &&
          groupId == other.groupId &&
          leaderId == other.leaderId &&
          term == other.term &&
          expiresAt == other.expiresAt &&
          sequence == other.sequence &&
          _mapEquals(_unknownFields, other._unknownFields);

  @override
  int get hashCode {
    var result = groupId.hashCode;
    result ^= leaderId.hashCode;
    result ^= term.hashCode;
    result ^= expiresAt.hashCode;
    result ^= sequence.hashCode;
    result ^= _unknownFields.hashCode;
    return result;
  }

  @override
  String toString() => 'LeaderLease(groupId=$groupId, leaderId=$leaderId, term=$term)';
}

/// RelayFrame — фрейм маршрутизации через промежуточные узлы.
///
/// Промежуточный узел видит только заголовок (dst, src, ttl, hop_count);
/// payload — end-to-end зашифрован и нечитаем для релея.
class RelayFrame {
  RelayFrame({
    required this.dst,
    required this.src,
    required this.ttl,
    required this.hopCount,
    required this.payload,
    this._unknownFields = const <int, Uint8List>{},
  });

  final Uint8List dst; // открытый ключ Ed25519 получателя
  final Uint8List src; // открытый ключ Ed25519 отправителя
  final int ttl; // время жизни в хопах
  final int hopCount; // пройдено хопов
  final Uint8List payload; // e2e зашифрованный payload
  final Map<int, Uint8List> _unknownFields;

  void writeTo(ProtoWriter writer) {
    writer.writeBytesField(1, dst);
    writer.writeBytesField(2, src);
    writer.writeVarintField(3, ttl);
    writer.writeVarintField(4, hopCount);
    if (payload.isNotEmpty) {
      writer.writeBytesField(5, payload);
    }
    writer.writeUnknownFields(_unknownFields);
  }

  Uint8List toBytes() {
    final writer = ProtoWriter();
    writeTo(writer);
    return writer.finish();
  }

  static RelayFrame fromBytes(Uint8List bytes) {
    return fromReader(ProtoReader(bytes));
  }

  static RelayFrame fromReader(ProtoReader reader) {
    final dst = <int>[];
    final src = <int>[];
    int ttl = 0;
    int hopCount = 0;
    final payload = <int>[];
    final unknown = <int, Uint8List>{};

    while (true) {
      final start = reader.mark();
      final tag = reader.readTag();
      if (tag == null) break;
      final (fieldNumber, wireType) = tag;
      switch (fieldNumber) {
        case 1:
          reader.readBytes().forEach(dst.add);
          break;
        case 2:
          reader.readBytes().forEach(src.add);
          break;
        case 3:
          ttl = reader.readVarint();
          break;
        case 4:
          hopCount = reader.readVarint();
          break;
        case 5:
          reader.readBytes().forEach(payload.add);
          break;
        default:
          reader.consumeField(wireType);
          unknown[fieldNumber] = reader.slice(start, reader.position);
          break;
      }
    }

    return RelayFrame(
      dst: Uint8List.fromList(dst),
      src: Uint8List.fromList(src),
      ttl: ttl,
      hopCount: hopCount,
      payload: Uint8List.fromList(payload),
      unknownFields: unknown,
    );
  }

  RelayFrame copyWith({
    Uint8List? dst,
    Uint8List? src,
    int? ttl,
    int? hopCount,
    Uint8List? payload,
    Map<int, Uint8List>? unknownFields,
  }) {
    return RelayFrame(
      dst: dst ?? this.dst,
      src: src ?? this.src,
      ttl: ttl ?? this.ttl,
      hopCount: hopCount ?? this.hopCount,
      payload: payload ?? this.payload,
      unknownFields: unknownFields ?? this._unknownFields,
    );
  }

  /// Уменьшает TTL на 1 и увеличивает hopCount на 1 (действие промежуточного узла).
  RelayFrame forward() {
    return copyWith(
      ttl: ttl > 0 ? ttl - 1 : 0,
      hopCount: hopCount + 1,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelayFrame &&
          runtimeType == other.runtimeType &&
          _bytesEquals(dst, other.dst) &&
          _bytesEquals(src, other.src) &&
          ttl == other.ttl &&
          hopCount == other.hopCount &&
          _bytesEquals(payload, other.payload) &&
          _mapEquals(_unknownFields, other._unknownFields);

  @override
  int get hashCode {
    var result = dst.hashCode;
    result ^= src.hashCode;
    result ^= ttl.hashCode;
    result ^= hopCount.hashCode;
    result ^= _bytesHash(payload);
    result ^= _unknownFields.hashCode;
    return result;
  }

  @override
  String toString() =>
      'RelayFrame(dstLen=${dst.length}, srcLen=${src.length}, ttl=$ttl, hopCount=$hopCount)';
}

/// Вспомогательные функции сравнения и хэширования без пакета collection.
int _bytesHash(Uint8List bytes) {
  var h = 0x811c9dc5; // FNV offset basis
  for (var i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = (h * 0x01000193) & 0xFFFFFFFF; // FNV prime, keep 32-bit
  }
  return h;
}

bool _bytesEquals(Uint8List? a, Uint8List? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _bytesListEquals(List<Uint8List> a, List<Uint8List> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_bytesEquals(a[i], b[i])) return false;
  }
  return true;
}

int _bytesListHash(List<Uint8List> list) {
  var h = 0;
  for (final bytes in list) {
    h ^= _bytesHash(bytes);
  }
  return h;
}

bool _stringListEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _stringListHash(List<String> list) {
  var h = 0;
  for (final s in list) {
    h ^= s.hashCode;
  }
  return h;
}

bool _mapEquals(Map<int, Uint8List> a, Map<int, Uint8List> b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    final bValue = b[key];
    if (bValue == null) return false;
    if (!_bytesEquals(a[key], bValue)) return false;
  }
  return true;
}
