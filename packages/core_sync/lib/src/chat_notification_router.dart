import 'package:core_domain/core_domain.dart';

class ChatNotificationRouter {
  ChatNotificationRouter({required this.notifications});

  final NotificationService notifications;
  final Set<String> _seen = <String>{};
  final Map<String, String> _channelOf = <String, String>{};

  Future<void> handle(
    ChatView view, {
    required UserId currentUser,
    required GroupId groupId,
    bool dnd = false,
  }) async {
    for (final message in view.messages) {
      if (_seen.contains(message.id)) continue;
      _seen.add(message.id);
      if (message.deleted || message.authorId == currentUser.value) continue;
      final kind = _kindOf(message, currentUser);
      if (kind == null) continue;
      if (dnd) continue;
      _channelOf[message.id] = message.channelId;
      await notifications.show(
        ChatNotification(
          id: message.id,
          groupId: groupId,
          channelId: view.channelId,
          messageId: message.id,
          authorId: UserId(message.authorId),
          preview: _preview(message.content),
          kind: kind,
          createdAt: message.timestamp,
        ),
      );
    }
  }

  Future<void> handleRead(
    ChatView view, {
    required UserId currentUser,
    bool allInChannel = false,
  }) {
    return markChannelRead(view.channelId);
  }

  Future<void> markChannelRead(ChannelId channelId) async {
    for (final id in _channelOf.keys.toList()) {
      final channel = _channelOf[id];
      if (channel != channelId.value) continue;
      await notifications.cancel(id);
      _channelOf.remove(id);
    }
  }

  ChatNotificationKind? _kindOf(ChatMessage message, UserId currentUser) {
    if (message.mentions.any((user) => user == currentUser)) {
      return ChatNotificationKind.mention;
    }
    if (message.replyToAuthorId == currentUser.value) {
      return ChatNotificationKind.reply;
    }
    return null;
  }

  String _preview(String content) {
    if (content.length <= 80) return content;
    return '${content.substring(0, 80)}…';
  }
}
