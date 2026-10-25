import 'dart:async';
import 'dart:convert';

import 'package:core_domain/core_domain.dart';

import 'bytes.dart';
import 'chat_codec.dart';
import 'chat_projection.dart';
import 'sync_engine_impl.dart';
import 'sync_event.dart';

class ChatServiceImpl implements ChatService {
  ChatServiceImpl({
    required this.engine,
    required this.localUser,
    this.bus,
    int Function()? nowMs,
    this.maxMessagesPerWindow = 10,
    this.rateWindow = const Duration(seconds: 10),
    this.typingTtl = const Duration(seconds: 6),
    this.codec = const ChatPayloadCodec(),
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SyncEngineImpl engine;
  final UserId localUser;
  final EphemeralChatBus? bus;
  final int maxMessagesPerWindow;
  final Duration rateWindow;
  final Duration typingTtl;
  final ChatPayloadCodec codec;
  final int Function() _nowMs;

  int _windowStart = 0;
  int _windowCount = 0;
  bool _closed = false;

  @override
  Future<Result<ChatMessage, ChatError>> send(
    GroupId groupId,
    ChannelId channelId,
    String text, {
    List<UserId> mentions = const <UserId>[],
    List<ChatAttachment> attachments = const <ChatAttachment>[],
  }) {
    return _send(
      groupId,
      channelId,
      text,
      mentions: mentions,
      attachments: attachments,
    );
  }

  @override
  Future<Result<ChatMessage, ChatError>> reply(
    GroupId groupId,
    ChannelId channelId,
    String replyTo,
    String text, {
    List<UserId> mentions = const <UserId>[],
    List<ChatAttachment> attachments = const <ChatAttachment>[],
  }) async {
    if (replyTo.isEmpty) return const Err(InvalidMessage('empty reply target'));
    final target = await _messageEvent(groupId, channelId, replyTo);
    if (target == null) return const Err(MessageNotFound());
    return _send(
      groupId,
      channelId,
      text,
      replyTo: replyTo,
      mentions: mentions,
      attachments: attachments,
    );
  }

  Future<Result<ChatMessage, ChatError>> _send(
    GroupId groupId,
    ChannelId channelId,
    String text, {
    String? replyTo,
    List<UserId> mentions = const <UserId>[],
    List<ChatAttachment> attachments = const <ChatAttachment>[],
  }) async {
    if (_closed) return const Err(ChatAccessDenied());
    final invalid = _validate(text, mentions, attachments);
    if (invalid != null) return Err(invalid);
    if (!_allowRate()) return const Err(RateLimited());

    final payload = codec.encode(
      ChatPayload(
        text: text,
        replyTo: replyTo,
        mentions: mentions,
        attachments: attachments,
      ),
    );
    final created = await engine.createEvent(
      groupId: groupId,
      channelId: channelId,
      kind: SyncEventKind.messageCreated,
      payload: payload,
    );
    if (created.isErr) return Err(ChatStorageFailure(created.unwrapErr()));
    final event = created.unwrap();
    return Ok(
      ChatMessage(
        id: event.id.value,
        channelId: channelId.value,
        authorId: localUser.value,
        content: text,
        timestamp: event.hlc.physicalMs,
        replyTo: replyTo,
        mentions: List<UserId>.unmodifiable(mentions),
        attachments: List<ChatAttachment>.unmodifiable(attachments),
      ),
    );
  }

  @override
  Future<Result<void, ChatError>> edit(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
    String text, {
    List<UserId>? mentions,
  }) async {
    final target = await _messageEvent(groupId, channelId, messageId);
    if (target == null) return const Err(MessageNotFound());
    if (target.authorId != localUser) return const Err(NotMessageAuthor());
    final invalid = _validate(text, mentions ?? const <UserId>[], const []);
    if (invalid != null) return Err(invalid);
    final payload = codec.encode(
      ChatPayload(text: text, mentions: mentions ?? const <UserId>[]),
    );
    final created = await engine.createEvent(
      groupId: groupId,
      channelId: channelId,
      kind: SyncEventKind.messageEdited,
      targetId: messageId,
      payload: payload,
    );
    if (created.isErr) return Err(ChatStorageFailure(created.unwrapErr()));
    return const Ok(null);
  }

  @override
  Future<Result<void, ChatError>> delete(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
  ) async {
    final target = await _messageEvent(groupId, channelId, messageId);
    if (target == null) return const Err(MessageNotFound());
    if (target.authorId != localUser) return const Err(NotMessageAuthor());
    final created = await engine.createEvent(
      groupId: groupId,
      channelId: channelId,
      kind: SyncEventKind.messageDeleted,
      targetId: messageId,
    );
    if (created.isErr) return Err(ChatStorageFailure(created.unwrapErr()));
    return const Ok(null);
  }

  @override
  Future<Result<void, ChatError>> setReaction(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
    String emoji, {
    bool active = true,
  }) async {
    final target = await _messageEvent(groupId, channelId, messageId);
    if (target == null) return const Err(MessageNotFound());
    if (emoji.isEmpty || utf8.encode(emoji).length > ChatLimits.maxEmojiBytes) {
      return const Err(InvalidMessage('invalid reaction'));
    }
    final created = await engine.createEvent(
      groupId: groupId,
      channelId: channelId,
      kind: SyncEventKind.messageReactionSet,
      targetId: messageId,
      payload: codec.encodeReaction(
        ReactionPayload(emoji: emoji, active: active),
      ),
    );
    if (created.isErr) return Err(ChatStorageFailure(created.unwrapErr()));
    return const Ok(null);
  }

  @override
  Future<Result<void, ChatError>> markRead(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
  ) async {
    final target = await _messageEvent(groupId, channelId, messageId);
    if (target == null) return const Err(MessageNotFound());
    final created = await engine.createEvent(
      groupId: groupId,
      channelId: channelId,
      kind: SyncEventKind.readMarked,
      targetId: messageId,
    );
    if (created.isErr) return Err(ChatStorageFailure(created.unwrapErr()));
    return const Ok(null);
  }

  @override
  Future<void> setTyping(
    GroupId groupId,
    ChannelId channelId,
    bool typing,
  ) async {
    final ephemeral = bus;
    if (ephemeral == null) return;
    final now = _nowMs();
    await ephemeral.publish(
      EphemeralChatEvent.typing(
        userId: localUser,
        channelId: channelId,
        expiresAtMs: typing ? now + typingTtl.inMilliseconds : now,
      ),
    );
  }

  @override
  Future<ChatView> view(GroupId groupId, ChannelId channelId) async {
    final events = await engine.allEvents(groupId);
    return ChatProjection.fromEvents(events).view(channelId);
  }

  @override
  Stream<ChatView> watch(GroupId groupId, ChannelId channelId) async* {
    yield await view(groupId, channelId);
    await for (final _ in engine.changes) {
      yield await view(groupId, channelId);
    }
  }

  Future<SyncEvent?> _messageEvent(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
  ) async {
    if (messageId.isEmpty) return null;
    final event = await engine.eventById(messageId);
    if (event == null ||
        event.groupId != groupId ||
        event.channelId != channelId ||
        event.kind != SyncEventKind.messageCreated) {
      return null;
    }
    return event;
  }

  ChatError? _validate(
    String text,
    List<UserId> mentions,
    List<ChatAttachment> attachments,
  ) {
    if (utf8.encode(text).length > ChatLimits.maxTextBytes) {
      return const MessageTooLarge();
    }
    if (mentions.length > ChatLimits.maxMentions) {
      return const InvalidMessage('too many mentions');
    }
    for (final mention in mentions) {
      final bytes = hexDecode(mention.value);
      if (bytes == null || bytes.length != 32) {
        return const InvalidMessage('invalid mention id');
      }
    }
    if (attachments.length > ChatLimits.maxAttachments) {
      return const InvalidMessage('too many attachments');
    }
    for (final attachment in attachments) {
      if (attachment.fileId.isEmpty || attachment.size < 0) {
        return const InvalidMessage('invalid attachment');
      }
    }
    return null;
  }

  bool _allowRate() {
    final now = _nowMs();
    if (now - _windowStart >= rateWindow.inMilliseconds) {
      _windowStart = now;
      _windowCount = 0;
    }
    if (_windowCount >= maxMessagesPerWindow) return false;
    _windowCount++;
    return true;
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}
