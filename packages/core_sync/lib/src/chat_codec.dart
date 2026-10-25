import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_protocol/core_protocol.dart';

class ChatPayload {
  const ChatPayload({
    required this.text,
    this.replyTo,
    this.mentions = const <UserId>[],
    this.attachments = const <ChatAttachment>[],
  });

  final String text;
  final String? replyTo;
  final List<UserId> mentions;
  final List<ChatAttachment> attachments;
}

class ReactionPayload {
  const ReactionPayload({required this.emoji, required this.active});

  final String emoji;
  final bool active;
}

class ChatPayloadCodec {
  const ChatPayloadCodec();

  Uint8List encode(ChatPayload payload) {
    final writer = ProtoWriter();
    writer.writeVarintField(1, 1);
    writer.writeStringField(2, payload.text);
    final replyTo = payload.replyTo;
    if (replyTo != null && replyTo.isNotEmpty) {
      writer.writeStringField(3, replyTo);
    }
    for (final mention in payload.mentions) {
      writer.writeStringField(4, mention.value);
    }
    for (final attachment in payload.attachments) {
      writer.writeBytesField(5, _encodeAttachment(attachment));
    }
    return writer.finish();
  }

  ChatPayload? decode(Uint8List bytes) {
    try {
      final reader = ProtoReader(bytes);
      var version = 0;
      var text = '';
      String? replyTo;
      final mentions = <UserId>[];
      final attachments = <ChatAttachment>[];
      while (true) {
        final tag = reader.readTag();
        if (tag == null) break;
        final (field, wireType) = tag;
        switch (field) {
          case 1:
            version = reader.readVarint();
          case 2:
            text = reader.readStringField();
          case 3:
            replyTo = reader.readStringField();
          case 4:
            mentions.add(UserId(reader.readStringField()));
          case 5:
            final attachment = _decodeAttachment(reader.readBytes());
            if (attachment != null) attachments.add(attachment);
          default:
            reader.consumeField(wireType);
        }
      }
      if (version != 1) return null;
      return ChatPayload(
        text: text,
        replyTo: (replyTo == null || replyTo.isEmpty) ? null : replyTo,
        mentions: mentions,
        attachments: attachments,
      );
    } catch (_) {
      return null;
    }
  }

  Uint8List encodeReaction(ReactionPayload payload) {
    final writer = ProtoWriter();
    writer.writeVarintField(1, 1);
    writer.writeStringField(2, payload.emoji);
    writer.writeVarintField(3, payload.active ? 1 : 0);
    return writer.finish();
  }

  ReactionPayload? decodeReaction(Uint8List bytes) {
    try {
      final reader = ProtoReader(bytes);
      var version = 0;
      var emoji = '';
      var active = false;
      while (true) {
        final tag = reader.readTag();
        if (tag == null) break;
        final (field, wireType) = tag;
        switch (field) {
          case 1:
            version = reader.readVarint();
          case 2:
            emoji = reader.readStringField();
          case 3:
            active = reader.readVarint() != 0;
          default:
            reader.consumeField(wireType);
        }
      }
      if (version != 1) return null;
      return ReactionPayload(emoji: emoji, active: active);
    } catch (_) {
      return null;
    }
  }

  String legacyText(Uint8List bytes) =>
      utf8.decode(bytes, allowMalformed: true);

  Uint8List _encodeAttachment(ChatAttachment attachment) {
    final writer = ProtoWriter();
    writer.writeStringField(1, attachment.fileId);
    writer.writeStringField(2, attachment.fileName);
    writer.writeStringField(3, attachment.mimeType);
    writer.writeVarintField(4, attachment.size);
    writer.writeVarintField(5, attachment.chunkSize);
    writer.writeVarintField(6, attachment.chunkCount);
    if (attachment.thumbnailId.isNotEmpty) {
      writer.writeStringField(7, attachment.thumbnailId);
    }
    return writer.finish();
  }

  ChatAttachment? _decodeAttachment(Uint8List bytes) {
    try {
      final reader = ProtoReader(bytes);
      var fileId = '';
      var fileName = '';
      var mimeType = '';
      var size = 0;
      var chunkSize = 0;
      var chunkCount = 0;
      var thumbnailId = '';
      while (true) {
        final tag = reader.readTag();
        if (tag == null) break;
        final (field, wireType) = tag;
        switch (field) {
          case 1:
            fileId = reader.readStringField();
          case 2:
            fileName = reader.readStringField();
          case 3:
            mimeType = reader.readStringField();
          case 4:
            size = reader.readVarint();
          case 5:
            chunkSize = reader.readVarint();
          case 6:
            chunkCount = reader.readVarint();
          case 7:
            thumbnailId = reader.readStringField();
          default:
            reader.consumeField(wireType);
        }
      }
      if (fileId.isEmpty) return null;
      return ChatAttachment(
        fileId: fileId,
        fileName: fileName,
        mimeType: mimeType,
        size: size,
        chunkSize: chunkSize,
        chunkCount: chunkCount,
        thumbnailId: thumbnailId,
      );
    } catch (_) {
      return null;
    }
  }
}
