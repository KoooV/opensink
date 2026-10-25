import 'dart:async';

import 'package:app/notifications/chat_notification_bridge.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:flutter_test/flutter_test.dart';

const _group = GroupId('group-1');
const _channel = ChannelId('general');
const _otherChannel = ChannelId('random');
const _me = UserId('me');

ChatMessage _message(
  String id, {
  String author = 'other',
  String channel = 'general',
  List<UserId> mentions = const <UserId>[],
  bool deleted = false,
  String? replyToAuthorId,
}) {
  return ChatMessage(
    id: id,
    channelId: channel,
    authorId: author,
    content: 'text $id',
    timestamp: int.parse(id.substring(1)),
    mentions: mentions,
    deleted: deleted,
    replyToAuthorId: replyToAuthorId,
  );
}

ChatView _view(List<ChatMessage> messages, {String channel = 'general'}) {
  return ChatView(
    channelId: ChannelId(channel),
    messages: messages,
    readMarkers: const {},
  );
}

Future<void> _flush() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeChatService chat;
  late FakeNotificationService notifications;
  late ChatNotificationRouter router;
  late ChatNotificationBridge bridge;

  setUp(() async {
    chat = _FakeChatService();
    notifications = FakeNotificationService();
    router = ChatNotificationRouter(notifications: notifications);
    bridge = ChatNotificationBridge(
      chat: chat,
      router: router,
      groupId: _group,
      currentUser: _me,
      channels: const [_channel, _otherChannel],
    );
    await bridge.start();
  });

  tearDown(() async {
    await bridge.close();
    await chat.close();
  });

  test('упоминание из ChatService уходит в уведомление с groupId', () async {
    chat.emit(
      _view([
        _message('m1', mentions: const [_me]),
      ]),
    );
    await _flush();

    expect(notifications.shown, hasLength(1));
    final shown = notifications.shown.single;
    expect(shown.groupId, _group);
    expect(shown.channelId, _channel);
    expect(shown.messageId, 'm1');
    expect(shown.kind, ChatNotificationKind.mention);
  });

  test('свои, удалённые и неадресованные сообщения игнорируются', () async {
    chat.emit(
      _view([
        _message('m1', author: 'me', mentions: const [_me]),
        _message('m2', mentions: const [_me], deleted: true),
        _message('m3'),
        _message('m4', replyToAuthorId: 'me'),
      ]),
    );
    await _flush();

    expect(notifications.shown, hasLength(1));
    expect(notifications.shown.single.messageId, 'm4');
    expect(notifications.shown.single.kind, ChatNotificationKind.reply);
  });

  test('повторный snapshot не дублирует уведомление', () async {
    final view = _view([
      _message('m1', mentions: const [_me]),
    ]);
    chat.emit(view);
    chat.emit(view);
    await _flush();

    expect(notifications.shown, hasLength(1));
  });

  test('DND скрывает уведомление и не откладывает его', () async {
    await bridge.close();
    final dndNotifications = FakeNotificationService();
    final dndRouter = ChatNotificationRouter(notifications: dndNotifications);
    final dndBridge = ChatNotificationBridge(
      chat: chat,
      router: dndRouter,
      groupId: _group,
      currentUser: _me,
      channels: const [_channel],
      isDnd: () => true,
    );
    await dndBridge.start();
    final view = _view([
      _message('m1', mentions: const [_me]),
    ]);
    chat.emit(view);
    await _flush();
    expect(dndNotifications.shown, isEmpty);

    await dndBridge.close();
    chat.emit(view);
    await _flush();
    expect(dndNotifications.shown, isEmpty);
  });

  test(
    'чтение канала отменяет только его уведомления и ставит read marker',
    () async {
      chat.emit(
        _view([
          _message('m1', mentions: const [_me]),
          _message('m2', mentions: const [_me]),
        ]),
      );
      chat.emit(
        _view([
          _message('m3', channel: 'random', mentions: const [_me]),
        ], channel: 'random'),
      );
      await _flush();
      expect(notifications.shown, hasLength(3));

      await bridge.readChannel(_channel);

      expect(notifications.cancelled, containsAll(['m1', 'm2']));
      expect(notifications.cancelled, isNot(contains('m3')));
      expect(chat.markedRead, contains((_group, _channel, 'm2')));
    },
  );

  test('после close новые события не уведомляют', () async {
    await bridge.close();

    chat.emit(
      _view([
        _message('m1', mentions: const [_me]),
      ]),
    );
    await _flush();

    expect(notifications.shown, isEmpty);
    expect(chat.activeListeners, 0);
  });

  test('updateChannels подписывает новый канал', () async {
    await bridge.updateChannels(const [
      _channel,
      _otherChannel,
      ChannelId('new'),
    ]);

    chat.emit(
      _view([
        _message('m1', channel: 'new', mentions: const [_me]),
      ], channel: 'new'),
    );
    await _flush();

    expect(notifications.shown.single.channelId, const ChannelId('new'));
  });
}

class _FakeChatService implements ChatService {
  final Map<ChannelId, StreamController<ChatView>> _controllers = {};
  final Set<ChannelId> _listening = <ChannelId>{};
  final List<(GroupId, ChannelId, String)> markedRead = [];

  int get activeListeners => _listening.length;

  void emit(ChatView view) {
    // ignore: close_sinks
    final controller = _controllers[view.channelId];
    if (controller == null || !_listening.contains(view.channelId)) return;
    controller.add(view);
  }

  @override
  Stream<ChatView> watch(GroupId groupId, ChannelId channelId) {
    // ignore: close_sinks
    final controller = _controllers.putIfAbsent(
      channelId,
      () => StreamController<ChatView>.broadcast(
        sync: true,
        onListen: () => _listening.add(channelId),
        onCancel: () => _listening.remove(channelId),
      ),
    );
    return controller.stream;
  }

  @override
  Future<void> setTyping(
    GroupId groupId,
    ChannelId channelId,
    bool typing,
  ) async {}

  @override
  Future<Result<void, ChatError>> markRead(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
  ) async {
    markedRead.add((groupId, channelId, messageId));
    return const Ok(null);
  }

  @override
  Future<Result<ChatMessage, ChatError>> send(
    GroupId groupId,
    ChannelId channelId,
    String text, {
    List<UserId> mentions = const <UserId>[],
    List<ChatAttachment> attachments = const <ChatAttachment>[],
  }) async {
    throw UnimplementedError();
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
    throw UnimplementedError();
  }

  @override
  Future<Result<void, ChatError>> edit(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
    String text, {
    List<UserId>? mentions,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Result<void, ChatError>> delete(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<Result<void, ChatError>> setReaction(
    GroupId groupId,
    ChannelId channelId,
    String messageId,
    String emoji, {
    bool active = true,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<ChatView> view(GroupId groupId, ChannelId channelId) async {
    throw UnimplementedError();
  }

  @override
  Future<void> close() async {
    for (final controller in _controllers.values) {
      await controller.close();
    }
    _controllers.clear();
    _listening.clear();
  }
}
