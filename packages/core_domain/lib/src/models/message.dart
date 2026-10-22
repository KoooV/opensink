import 'identifiers.dart';

/// Сообщение в текстовом канале.
class Message {
  const Message({
    required this.id,
    required this.channelId,
    required this.groupId,
    required this.authorId,
    required this.content,
    required this.createdAt,
    this.replyTo,
    this.editedAt,
  });

  final MessageId id;
  final ChannelId channelId;
  final GroupId groupId;
  final UserId authorId;
  final String content;
  final int createdAt; // Unix ms
  final MessageId? replyTo;
  final int? editedAt; // Unix ms

  Message copyWith({
    MessageId? id,
    ChannelId? channelId,
    GroupId? groupId,
    UserId? authorId,
    String? content,
    int? createdAt,
    MessageId? replyTo,
    int? editedAt,
  }) {
    return Message(
      id: id ?? this.id,
      channelId: channelId ?? this.channelId,
      groupId: groupId ?? this.groupId,
      authorId: authorId ?? this.authorId,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      replyTo: replyTo ?? this.replyTo,
      editedAt: editedAt ?? this.editedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Message && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Message(id=$id, author=$authorId, content=$content)';
}
