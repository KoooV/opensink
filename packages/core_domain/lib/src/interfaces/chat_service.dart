import '../models/chat.dart';
import '../models/identifiers.dart';
import '../result.dart';

abstract class ChatService {
  Future<Result<ChatMessage, ChatError>> send(
    GroupId groupId,
    ChannelId channelId,
    String text, {
    List<UserId> mentions = const <UserId>[],
    List<ChatAttachment> attachments = const <ChatAttachment>[],
  });

  Future<Result<ChatMessage, ChatError>> reply(
    GroupId groupId,
    ChannelId channelId,
    String replyTo,
    String text, {
    List<UserId> mentions = const <UserId>[],
    List<ChatAttachment> attachments = const <ChatAttachment>[],
  });

  Future<Result<void, ChatError>> edit(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
    String text, {
    List<UserId>? mentions,
  });

  Future<Result<void, ChatError>> delete(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
  );

  Future<Result<void, ChatError>> setReaction(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
    String emoji, {
    bool active = true,
  });

  Future<Result<void, ChatError>> markRead(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
  );

  Future<void> setTyping(GroupId groupId, ChannelId channelId, bool typing);

  Future<ChatView> view(GroupId groupId, ChannelId channelId);

  Stream<ChatView> watch(GroupId groupId, ChannelId channelId);

  Future<void> close();
}
