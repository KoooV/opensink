import 'identifiers.dart';

class ChatAttachment {
  const ChatAttachment({
    required this.fileId,
    required this.fileName,
    required this.mimeType,
    required this.size,
    required this.chunkSize,
    required this.chunkCount,
    this.thumbnailId = '',
  });

  final String fileId;
  final String fileName;
  final String mimeType;
  final int size;
  final int chunkSize;
  final int chunkCount;
  final String thumbnailId;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.channelId,
    required this.authorId,
    required this.content,
    required this.timestamp,
    this.replyTo,
    this.replyToAuthorId,
    this.mentions = const <UserId>[],
    this.attachments = const <ChatAttachment>[],
    this.reactions = const <String, Set<String>>{},
    this.edited = false,
    this.deleted = false,
  });

  final String id;
  final String channelId;
  final String authorId;
  final String content;
  final int timestamp;
  final String? replyTo;
  final String? replyToAuthorId;
  final List<UserId> mentions;
  final List<ChatAttachment> attachments;
  final Map<String, Set<String>> reactions;
  final bool edited;
  final bool deleted;

  ChatMessage copyWith({
    String? content,
    String? replyToAuthorId,
    List<UserId>? mentions,
    Map<String, Set<String>>? reactions,
    bool? edited,
    bool? deleted,
  }) {
    return ChatMessage(
      id: id,
      channelId: channelId,
      authorId: authorId,
      content: content ?? this.content,
      timestamp: timestamp,
      replyTo: replyTo,
      replyToAuthorId: replyToAuthorId ?? this.replyToAuthorId,
      mentions: mentions ?? this.mentions,
      attachments: attachments,
      reactions: reactions ?? this.reactions,
      edited: edited ?? this.edited,
      deleted: deleted ?? this.deleted,
    );
  }
}

class ReadMarker {
  const ReadMarker({
    required this.channelId,
    required this.userId,
    required this.messageId,
    required this.hlcMs,
  });

  final ChannelId channelId;
  final UserId userId;
  final String messageId;
  final int hlcMs;

  String get key => '${channelId.value}:${userId.value}';
}

class ChatView {
  const ChatView({
    required this.channelId,
    required this.messages,
    required this.readMarkers,
  });

  final ChannelId channelId;
  final List<ChatMessage> messages;
  final Map<String, ReadMarker> readMarkers;
}

abstract final class ChatLimits {
  static const int maxTextBytes = 16 * 1024;
  static const int maxMentions = 64;
  static const int maxAttachments = 10;
  static const int maxEmojiBytes = 64;
  static const int maxMessagesPerMinute = 120;
}

sealed class ChatError {
  const ChatError();
}

class MessageTooLarge extends ChatError {
  const MessageTooLarge();
}

class InvalidMessage extends ChatError {
  const InvalidMessage(this.reason);
  final String reason;

  @override
  String toString() => 'InvalidMessage($reason)';
}

class RateLimited extends ChatError {
  const RateLimited();
}

class MessageNotFound extends ChatError {
  const MessageNotFound();
}

class NotMessageAuthor extends ChatError {
  const NotMessageAuthor();
}

class ChatAccessDenied extends ChatError {
  const ChatAccessDenied();
}

class ChatStorageFailure extends ChatError {
  const ChatStorageFailure(this.error);
  final Object error;

  @override
  String toString() => 'ChatStorageFailure($error)';
}
