import 'dart:async';

import 'package:core_domain/core_domain.dart';

class PresenceServiceImpl implements PresenceService {
  PresenceServiceImpl({
    required this.bus,
    required this.localUser,
    int Function()? nowMs,
    this.presenceTtl = const Duration(seconds: 90),
    this.typingTtl = const Duration(seconds: 6),
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _subscription = bus.incoming.listen(_onEvent);
  }

  final EphemeralChatBus bus;
  final UserId localUser;
  final Duration presenceTtl;
  final Duration typingTtl;
  final int Function() _nowMs;
  final Map<UserId, UserPresence> _peers = <UserId, UserPresence>{};
  final Map<ChannelId, Map<UserId, int>> _typing =
      <ChannelId, Map<UserId, int>>{};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  StreamSubscription<EphemeralChatEvent>? _subscription;
  UserPresenceStatus _localStatus = UserPresenceStatus.online;
  ChannelId? _localVoiceChannel;
  bool _closed = false;

  @override
  Map<UserId, UserPresence> get peers {
    _prune();
    return Map<UserId, UserPresence>.unmodifiable(_peers);
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Set<UserId> typingIn(ChannelId channelId) {
    final now = _nowMs();
    final channel = _typing[channelId];
    if (channel == null) return const <UserId>{};
    channel.removeWhere((_, expiresAt) => now >= expiresAt);
    if (channel.isEmpty) _typing.remove(channelId);
    return Set<UserId>.unmodifiable(channel.keys);
  }

  @override
  Future<void> setStatus(UserPresenceStatus status) async {
    _localStatus = status;
    await _publishPresence();
  }

  @override
  Future<void> setVoiceChannel(ChannelId? channelId) async {
    _localVoiceChannel = channelId;
    await _publishPresence();
  }

  @override
  Future<void> setTyping(ChannelId channelId, bool typing) async {
    final now = _nowMs();
    await bus.publish(
      EphemeralChatEvent.typing(
        userId: localUser,
        channelId: channelId,
        expiresAtMs: typing ? now + typingTtl.inMilliseconds : now,
      ),
    );
  }

  Future<void> _publishPresence() async {
    final now = _nowMs();
    final event = EphemeralChatEvent.presence(
      userId: localUser,
      status: _localStatus,
      voiceChannelId: _localVoiceChannel?.value,
      expiresAtMs: now + presenceTtl.inMilliseconds,
    );
    _apply(event);
    await bus.publish(event);
  }

  void _onEvent(EphemeralChatEvent event) {
    if (_closed || event.isExpired(_nowMs())) return;
    _apply(event);
    if (!_changes.isClosed) _changes.add(null);
  }

  void _apply(EphemeralChatEvent event) {
    switch (event.kind) {
      case EphemeralChatEventKind.presence:
        final status = event.status;
        if (status == null) return;
        _peers[event.userId] = UserPresence(
          userId: event.userId,
          status: status,
          voiceChannelId: event.voiceChannelId,
          expiresAtMs: event.expiresAtMs,
        );
      case EphemeralChatEventKind.typing:
        final channel = event.channelId;
        if (channel == null) return;
        final users = _typing.putIfAbsent(channel, () => <UserId, int>{});
        users[event.userId] = event.expiresAtMs;
    }
  }

  void _prune() {
    final now = _nowMs();
    _peers.removeWhere((_, presence) => presence.isExpired(now));
    for (final entry in _typing.entries.toList()) {
      entry.value.removeWhere((_, expiresAt) => now >= expiresAt);
      if (entry.value.isEmpty) _typing.remove(entry.key);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _changes.close();
  }
}
