import 'dart:async';

import 'package:app/di/providers.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_storage/core_storage.dart';
import 'package:core_sync/core_sync.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _group = GroupId('group-1');
const _me = UserId('local-user');

Future<void> _flush() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('chatServiceProvider строит production ChatServiceImpl', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.open(backend: 'memory', isPersistent: false);
    final store = DriftEventStore(db);
    final engine = SyncEngineImpl(
      store: store,
      signer: FakeSigner(),
      localAuthor: _me,
    );
    addTearDown(() async {
      await engine.close();
      await store.close();
      await db.close();
    });
    final container = ProviderContainer(
      overrides: [
        syncEngineProvider.overrideWith((ref) async => engine),
        localIdentityProvider.overrideWith(
          (ref) async => LocalIdentity(userId: _me, signer: FakeSigner()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final service = await container.read(chatServiceProvider(_group).future);

    expect(service, isA<ChatServiceImpl>());
    expect((service as ChatServiceImpl).localUser, _me);
  });

  test('bridge подписывается на каналы группы и general', () async {
    final chat = _FakeChatService();
    final notifications = FakeNotificationService();
    final container = ProviderContainer(
      overrides: [
        chatServiceProvider.overrideWith((ref, groupId) async => chat),
        groupStateProvider.overrideWith(
          (ref, groupId) async => _FixedGroupState(
            GroupState(
              id: groupId,
              name: 'test',
              ownerId: _me,
              memberIds: <UserId>{_me},
              channelIds: <ChannelId>{const ChannelId('random')},
              createdAt: 1,
              updatedAt: 1,
            ),
          ),
        ),
        localIdentityProvider.overrideWith(
          (ref) async => LocalIdentity(userId: _me, signer: FakeSigner()),
        ),
        notificationRouterProvider.overrideWithValue(
          ChatNotificationRouter(notifications: notifications),
        ),
      ],
    );
    addTearDown(chat.close);
    addTearDown(container.dispose);

    final subscription = container.listen(
      chatNotificationBridgeProvider(_group),
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    await container.read(chatNotificationBridgeProvider(_group).future);
    chat.emit(_view('m1', 'general'));
    chat.emit(_view('m2', 'random'));
    await _flush();

    expect(
      notifications.shown.map((notification) => notification.channelId),
      containsAll(const [ChannelId('general'), ChannelId('random')]),
    );

    container.read(chatDndProvider.notifier).state = true;
    chat.emit(_view('m3', 'general'));
    await _flush();
    expect(notifications.shown, hasLength(2));

    container.read(chatDndProvider.notifier).state = false;
    chat.emit(_view('m4', 'general'));
    await _flush();
    expect(notifications.shown, hasLength(3));
  });
}

ChatView _view(String id, String channel) {
  return ChatView(
    channelId: ChannelId(channel),
    messages: [
      ChatMessage(
        id: id,
        channelId: channel,
        authorId: 'other',
        content: 'text',
        timestamp: 1,
        mentions: const [_me],
      ),
    ],
    readMarkers: const {},
  );
}

class _FixedGroupState implements IGroupState {
  const _FixedGroupState(this.state);

  @override
  final GroupState state;

  @override
  Stream<GroupState> watch() => Stream<GroupState>.value(state);
}

class _FakeChatService implements ChatService {
  final Map<ChannelId, StreamController<ChatView>> _controllers = {};

  void emit(ChatView view) {
    // ignore: close_sinks
    final controller = _controllers[view.channelId];
    controller?.add(view);
  }

  @override
  Stream<ChatView> watch(GroupId groupId, ChannelId channelId) {
    // ignore: close_sinks
    final controller = _controllers.putIfAbsent(
      channelId,
      () => StreamController<ChatView>.broadcast(sync: true),
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
    return const Ok(null);
  }

  @override
  Future<void> close() async {
    for (final controller in _controllers.values) {
      await controller.close();
    }
    _controllers.clear();
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
}
