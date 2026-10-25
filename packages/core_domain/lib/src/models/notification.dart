import 'identifiers.dart';

enum ChatNotificationKind { message, mention, reply }

class ChatNotification {
  const ChatNotification({
    required this.id,
    required this.groupId,
    required this.channelId,
    required this.messageId,
    required this.authorId,
    required this.preview,
    required this.kind,
    required this.createdAt,
  });

  final String id;
  final GroupId groupId;
  final ChannelId channelId;
  final String messageId;
  final UserId authorId;
  final String preview;
  final ChatNotificationKind kind;
  final int createdAt;
}

abstract class NotificationService {
  Future<void> show(ChatNotification notification);

  Future<void> cancel(String id);

  Future<void> cancelAll();
}
