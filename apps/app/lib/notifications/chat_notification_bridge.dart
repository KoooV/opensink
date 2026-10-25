import 'dart:async';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';

/// Связывает production [ChatService] с [ChatNotificationRouter].
///
/// Подписывается на каналы группы и передаёт каждый снимок в роутер.
/// [readChannel] отменяет уведомления канала и публикует read marker.
class ChatNotificationBridge {
  ChatNotificationBridge({
    required this.chat,
    required this.router,
    required this.groupId,
    required this.currentUser,
    required Iterable<ChannelId> channels,
    bool Function()? isDnd,
  }) : _channels = channels.toSet(),
       _isDnd = isDnd ?? _notDnd;

  final ChatService chat;
  final ChatNotificationRouter router;
  final GroupId groupId;
  final UserId currentUser;
  final bool Function() _isDnd;

  final Set<ChannelId> _channels;
  final Map<ChannelId, StreamSubscription<ChatView>> _subscriptions =
      <ChannelId, StreamSubscription<ChatView>>{};
  final Map<ChannelId, ChatView> _latest = <ChannelId, ChatView>{};
  Future<void> _tail = Future<void>.value();
  bool _started = false;
  bool _closed = false;

  static bool _notDnd() => false;

  Future<void> start() async {
    if (_started || _closed) return;
    _started = true;
    for (final channel in _channels.toList()) {
      _subscribe(channel);
    }
  }

  Future<void> updateChannels(Iterable<ChannelId> channels) async {
    if (_closed) return;
    final next = channels.toSet();
    _channels
      ..clear()
      ..addAll(next);
    for (final channel in _subscriptions.keys.toList()) {
      if (next.contains(channel)) continue;
      final subscription = _subscriptions.remove(channel);
      _latest.remove(channel);
      await subscription?.cancel();
    }
    if (!_started) return;
    for (final channel in next) {
      _subscribe(channel);
    }
  }

  Future<void> readChannel(ChannelId channelId) async {
    if (_closed) return;
    await _tail;
    await router.markChannelRead(channelId);
    final messages = _latest[channelId]?.messages;
    if (messages == null || messages.isEmpty) return;
    await chat.markRead(groupId, channelId, messages.last.id);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final subscriptions = _subscriptions.values.toList();
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await _tail;
  }

  void _subscribe(ChannelId channelId) {
    if (_closed || _subscriptions.containsKey(channelId)) return;
    _subscriptions[channelId] = chat.watch(groupId, channelId).listen((view) {
      _latest[channelId] = view;
      _tail = _tail
          .then(
            (_) => router.handle(
              view,
              currentUser: currentUser,
              groupId: groupId,
              dnd: _isDnd(),
            ),
          )
          .catchError((Object _) {});
    }, onError: (Object _) {});
  }
}
