import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:meta/meta.dart';

/// Тип сигнального сообщения внутри защищённого конверта.
enum SignalingKind {
  hello(0),
  offer(1),
  answer(2),
  ice(3),
  hangup(4),
  data(5);

  const SignalingKind(this.wireValue);

  final int wireValue;

  static SignalingKind? fromWire(int value) {
    for (final kind in values) {
      if (kind.wireValue == value) {
        return kind;
      }
    }
    return null;
  }
}

/// Платформа узла для presence-анонса.
enum SignalingPlatform {
  unknown(0),
  android(1),
  linux(2),
  web(3);

  const SignalingPlatform(this.wireValue);

  final int wireValue;

  static SignalingPlatform fromWire(int value) {
    for (final platform in values) {
      if (platform.wireValue == value) {
        return platform;
      }
    }
    return SignalingPlatform.unknown;
  }
}

/// Возможности узла, публикуемые в hello.
@immutable
class NodeCapabilities {
  const NodeCapabilities({
    this.platform = SignalingPlatform.unknown,
    this.publicIpv6,
    this.uptime = Duration.zero,
    this.canRelay = false,
    this.canSfu = false,
    this.capacityBytesPerSecond = 0,
    this.neighbors = const <PeerId>[],
  });

  final SignalingPlatform platform;
  final String? publicIpv6;
  final Duration uptime;
  final bool canRelay;
  final bool canSfu;

  /// Заявленная ёмкость ретрансляции в байтах в секунду.
  final int capacityBytesPerSecond;
  final List<PeerId> neighbors;

  @override
  String toString() =>
      'NodeCapabilities(platform=$platform, uptime=$uptime, '
      'canRelay=$canRelay, canSfu=$canSfu, '
      'capacity=$capacityBytesPerSecond, neighbors=${neighbors.length})';
}

/// Канал, умеющий обновлять список direct-соседей в presence.
///
/// Отдельный интерфейс, чтобы не расширять [RichSignalingChannel] и не ломать
/// существующие реализации, которым топология не нужна.
abstract interface class NeighborAnnouncer {
  /// Заменяет `neighbors` в следующем hello-анонсе.
  Future<void> updateNeighbors(Iterable<PeerId> neighbors);
}

/// Presence-анонс удалённого узла.
@immutable
class PeerPresence {
  const PeerPresence({
    required this.topic,
    required this.peerId,
    required this.capabilities,
    required this.seenAt,
    required this.expiresAt,
  });

  final String topic;
  final PeerId peerId;
  final NodeCapabilities capabilities;
  final DateTime seenAt;
  final DateTime expiresAt;

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);

  @override
  String toString() => 'PeerPresence(topic=$topic, peerId=$peerId)';
}

/// Входящий сигнальный пакет с типом и адресатом.
@immutable
class SignalingPacket {
  const SignalingPacket({
    required this.topic,
    required this.kind,
    required this.from,
    required this.bytes,
    required this.timestamp,
    this.to,
  });

  final String topic;
  final SignalingKind kind;
  final PeerId from;
  final PeerId? to;
  final Uint8List bytes;

  /// Время отправки (Unix ms).
  final int timestamp;

  @override
  String toString() =>
      'SignalingPacket(topic=$topic, kind=$kind, from=$from, to=$to)';
}

/// Причина отклонения входящего пакета. Наружу не бросается.
enum SignalingReject {
  tooLarge,
  malformed,
  badVersion,
  badSignature,
  unauthorized,
  selfEcho,
  notForMe,
  expired,
  replayed,
  undecryptable,
  rateLimited,
  closed,
}

/// Ограничения и таймауты сигнализации.
@immutable
class SignalingLimits {
  const SignalingLimits({
    this.maxPacketBytes = 256 * 1024,
    this.maxBodyBytes = 128 * 1024,
    this.maxClockSkew = const Duration(minutes: 2),
    this.replayTtl = const Duration(minutes: 5),
    this.replayMaxEntries = 10000,
    this.rateCapacity = 40,
    this.rateRefillPerSecond = 20,
    this.perSenderRateCapacity = 20,
    this.perSenderRefillPerSecond = 10,
  });

  final int maxPacketBytes;
  final int maxBodyBytes;
  final Duration maxClockSkew;
  final Duration replayTtl;
  final int replayMaxEntries;
  final int rateCapacity;
  final double rateRefillPerSecond;
  final int perSenderRateCapacity;
  final double perSenderRefillPerSecond;
}

/// Health-снимок одного реле.
@immutable
class RelayHealth {
  const RelayHealth({
    required this.uri,
    required this.connected,
    required this.score,
    required this.consecutiveFailures,
    required this.totalFailures,
    required this.totalConnections,
    this.lastConnectedAt,
    this.lastMessageAt,
    this.lastError,
  });

  final Uri uri;
  final bool connected;

  /// 0.0–1.0, эвристика для выбора/диагностики.
  final double score;
  final int consecutiveFailures;
  final int totalFailures;
  final int totalConnections;
  final DateTime? lastConnectedAt;
  final DateTime? lastMessageAt;
  final String? lastError;

  @override
  String toString() =>
      'RelayHealth(uri=$uri, connected=$connected, score=$score, '
      'failures=$consecutiveFailures)';
}

/// Расширенный канал сигнализации с presence и адресными сообщениями.
abstract interface class RichSignalingChannel implements SignalingChannel {
  Stream<PeerPresence> get presence;
  Stream<SignalingPacket> get packets;

  /// Отправляет пакет с явным типом и опциональным адресатом.
  Future<void> publishTo(
    String topic, {
    required SignalingKind kind,
    PeerId? to,
    required List<int> bytes,
  });
}
