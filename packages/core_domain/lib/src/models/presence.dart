import 'dart:async';

import '../models/identifiers.dart';

enum UserPresenceStatus { online, idle, dnd, offline }

enum EphemeralChatEventKind { typing, presence }

class EphemeralChatEvent {
  const EphemeralChatEvent({
    required this.kind,
    required this.userId,
    required this.expiresAtMs,
    this.channelId,
    this.status,
    this.voiceChannelId,
  });

  factory EphemeralChatEvent.typing({
    required UserId userId,
    required ChannelId channelId,
    required int expiresAtMs,
  }) {
    return EphemeralChatEvent(
      kind: EphemeralChatEventKind.typing,
      userId: userId,
      channelId: channelId,
      expiresAtMs: expiresAtMs,
    );
  }

  factory EphemeralChatEvent.presence({
    required UserId userId,
    required UserPresenceStatus status,
    required int expiresAtMs,
    String? voiceChannelId,
  }) {
    return EphemeralChatEvent(
      kind: EphemeralChatEventKind.presence,
      userId: userId,
      status: status,
      voiceChannelId: voiceChannelId,
      expiresAtMs: expiresAtMs,
    );
  }

  final EphemeralChatEventKind kind;
  final UserId userId;
  final int expiresAtMs;
  final ChannelId? channelId;
  final UserPresenceStatus? status;
  final String? voiceChannelId;

  bool isExpired(int nowMs) => nowMs >= expiresAtMs;
}

abstract class EphemeralChatBus {
  Stream<EphemeralChatEvent> get incoming;

  Future<void> publish(EphemeralChatEvent event);

  Future<void> close();
}

class UserPresence {
  const UserPresence({
    required this.userId,
    required this.status,
    required this.expiresAtMs,
    this.voiceChannelId,
  });

  final UserId userId;
  final UserPresenceStatus status;
  final String? voiceChannelId;
  final int expiresAtMs;

  bool isExpired(int nowMs) => nowMs >= expiresAtMs;
}

abstract class PresenceService {
  Map<UserId, UserPresence> get peers;

  Stream<void> get changes;

  Set<UserId> typingIn(ChannelId channelId);

  Future<void> setStatus(UserPresenceStatus status);

  Future<void> setVoiceChannel(ChannelId? channelId);

  Future<void> setTyping(ChannelId channelId, bool typing);

  Future<void> close();
}
