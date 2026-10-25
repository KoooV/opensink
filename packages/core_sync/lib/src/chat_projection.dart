import 'package:core_domain/core_domain.dart';

import 'chat_codec.dart';
import 'sync_event.dart';

class ChatProjection {
  const ChatProjection({required this.messages, required this.readMarkers});

  final Map<String, ChatMessage> messages;
  final Map<String, ReadMarker> readMarkers;

  factory ChatProjection.fromEvents(Iterable<SyncEvent> events) {
    const codec = ChatPayloadCodec();
    final sorted = events.toList()..sort((a, b) => a.compareTo(b));
    final mutable = <String, _MutableMessage>{};

    for (final event in sorted) {
      if (event.kind != SyncEventKind.messageCreated) continue;
      final channel = event.channelId;
      if (channel == null) continue;
      final payload = codec.decode(event.payload);
      mutable[event.id.value] = _MutableMessage(
        id: event.id.value,
        channelId: channel.value,
        authorId: event.authorId.value,
        content: payload?.text ?? codec.legacyText(event.payload),
        timestamp: event.hlc.physicalMs,
        replyTo: payload?.replyTo,
        mentions: payload?.mentions ?? const <UserId>[],
        attachments: payload?.attachments ?? const <ChatAttachment>[],
      );
    }

    final readMarkers = <String, ReadMarker>{};
    for (final event in sorted) {
      final target = event.targetId;
      switch (event.kind) {
        case SyncEventKind.messageEdited:
          final message = target == null ? null : mutable[target];
          if (message == null || message.authorId != event.authorId.value) {
            break;
          }
          final payload = codec.decode(event.payload);
          message
            ..content = payload?.text ?? codec.legacyText(event.payload)
            ..mentions = payload?.mentions ?? message.mentions
            ..edited = true;
        case SyncEventKind.messageDeleted:
          final message = target == null ? null : mutable[target];
          if (message == null || message.authorId != event.authorId.value) {
            break;
          }
          message
            ..content = ''
            ..deleted = true;
        case SyncEventKind.messageReactionSet:
          final message = target == null ? null : mutable[target];
          if (message == null) break;
          final payload = codec.decodeReaction(event.payload);
          if (payload == null || payload.emoji.isEmpty) break;
          final users = message.reactions.putIfAbsent(
            payload.emoji,
            () => <String>{},
          );
          if (payload.active) {
            users.add(event.authorId.value);
          } else {
            users.remove(event.authorId.value);
            if (users.isEmpty) message.reactions.remove(payload.emoji);
          }
        case SyncEventKind.readMarked:
          final channel = event.channelId;
          if (channel == null || target == null || target.isEmpty) break;
          final marker = ReadMarker(
            channelId: channel,
            userId: event.authorId,
            messageId: target,
            hlcMs: event.hlc.physicalMs,
          );
          readMarkers[marker.key] = marker;
        default:
          break;
      }
    }

    for (final message in mutable.values) {
      final replyTo = message.replyTo;
      if (replyTo == null) continue;
      message.replyToAuthorId = mutable[replyTo]?.authorId;
    }

    final messages = <String, ChatMessage>{
      for (final entry in mutable.entries) entry.key: entry.value.freeze(),
    };
    return ChatProjection(messages: messages, readMarkers: readMarkers);
  }

  ChatView view(ChannelId channelId) {
    final visible =
        messages.values
            .where((message) => message.channelId == channelId.value)
            .toList()
          ..sort((a, b) {
            final byTime = a.timestamp.compareTo(b.timestamp);
            if (byTime != 0) return byTime;
            return a.id.compareTo(b.id);
          });
    final markers = <String, ReadMarker>{
      for (final entry in readMarkers.entries)
        if (entry.value.channelId == channelId)
          entry.value.userId.value: entry.value,
    };
    return ChatView(
      channelId: channelId,
      messages: List<ChatMessage>.unmodifiable(visible),
      readMarkers: Map<String, ReadMarker>.unmodifiable(markers),
    );
  }
}

class _MutableMessage {
  _MutableMessage({
    required this.id,
    required this.channelId,
    required this.authorId,
    required this.content,
    required this.timestamp,
    required this.replyTo,
    required this.mentions,
    required this.attachments,
  });

  final String id;
  final String channelId;
  final String authorId;
  String content;
  final int timestamp;
  final String? replyTo;
  String? replyToAuthorId;
  List<UserId> mentions;
  final List<ChatAttachment> attachments;
  final Map<String, Set<String>> reactions = <String, Set<String>>{};
  bool edited = false;
  bool deleted = false;

  ChatMessage freeze() {
    return ChatMessage(
      id: id,
      channelId: channelId,
      authorId: authorId,
      content: content,
      timestamp: timestamp,
      replyTo: replyTo,
      replyToAuthorId: replyToAuthorId,
      mentions: List<UserId>.unmodifiable(mentions),
      attachments: List<ChatAttachment>.unmodifiable(attachments),
      reactions: Map<String, Set<String>>.unmodifiable(
        reactions.map(
          (emoji, users) => MapEntry(emoji, Set<String>.unmodifiable(users)),
        ),
      ),
      edited: edited,
      deleted: deleted,
    );
  }
}
