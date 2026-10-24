import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide RelayFrame;
import 'package:core_protocol/core_protocol.dart' show RelayFrame;
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import 'relay_config.dart';
import 'relay_metrics.dart';
import 'relay_topology.dart';

/// Результат попытки доставки.
sealed class RelaySendResult {
  const RelaySendResult();
}

/// Данные ушли напрямую.
final class DirectSent extends RelaySendResult {
  const DirectSent();
}

/// Данные переданы релею.
final class RelayedSent extends RelaySendResult {
  const RelayedSent(this.relay);

  final PeerId relay;
}

/// Причина неудачи.
enum RelayFailureReason { closed, self, frameTooLarge, disabled, noRoute }

/// Доставить не удалось; для групп сообщение догонит sync.
final class RelaySendFailed extends RelaySendResult {
  const RelaySendFailed(this.reason);

  final RelayFailureReason reason;
}

/// Входящий кадр, адресованный локальному узлу.
@immutable
class RelayInbound {
  const RelayInbound({required this.src, required this.payload});

  final PeerId src;
  final List<int> payload;

  @override
  String toString() => 'RelayInbound(src=$src, bytes=${payload.length})';
}

/// Транспорт с прозрачным fallback на релей.
///
/// Прямая отправка идёт через [Transport.send]. Если ICE не уложился в
/// [RelayConfig.directTimeout], payload заворачивается в [RelayFrame] и
/// отправляется общему соседу. Промежуточный узел получает кадры через
/// [accept] (в production — из входящего канала `relay`) и видит только
/// заголовок: payload уже зашифрован отправителем.
class RelayTransport implements Transport {
  RelayTransport({
    required this.localPeerId,
    required this.direct,
    required this.topology,
    this.config = const RelayConfig(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _directEvents = direct.events.listen(
      _events.add,
      onError: _events.addError,
      onDone: _onDirectDone,
    );
  }

  final PeerId localPeerId;

  /// Транспорт прямых соединений (core_peer).
  final Transport direct;

  final RelayTopology topology;
  final RelayConfig config;
  final DateTime Function() _clock;

  final RelayMetrics metrics = RelayMetrics();
  final StreamController<PeerLinkEvent> _events =
      StreamController<PeerLinkEvent>.broadcast();
  final StreamController<RelayInbound> _incoming =
      StreamController<RelayInbound>.broadcast();

  final Map<String, DateTime> _seen = <String, DateTime>{};
  final Map<PeerId, _TokenBucket> _sourceBuckets = <PeerId, _TokenBucket>{};

  StreamSubscription<PeerLinkEvent>? _directEvents;
  bool _closed = false;

  /// Входящие payload'ы, дошедшие через релей.
  Stream<RelayInbound> get incoming => _incoming.stream;

  @override
  Stream<PeerLinkEvent> get events => _events.stream;

  @override
  Future<PeerLink> connect(PeerId peerId) => direct.connect(peerId);

  @override
  Future<void> send(PeerId dst, List<int> bytes) async {
    final result = await deliver(dst, bytes);
    if (result is RelaySendFailed) {
      throw StateError('relay send failed: ${result.reason.name}');
    }
  }

  /// Пытается доставить данные напрямую, затем через релей.
  Future<RelaySendResult> deliver(PeerId dst, List<int> bytes) async {
    if (_closed) {
      return const RelaySendFailed(RelayFailureReason.closed);
    }
    if (dst == localPeerId) {
      return const RelaySendFailed(RelayFailureReason.self);
    }
    if (bytes.length > config.maxFrameBytes) {
      metrics.droppedOversize += 1;
      return const RelaySendFailed(RelayFailureReason.frameTooLarge);
    }

    final payload = Uint8List.fromList(bytes);
    try {
      await direct.send(dst, payload).timeout(config.directTimeout);
      metrics.directSent += 1;
      return const DirectSent();
    } catch (_) {
      metrics.directFailed += 1;
      // Прямое соединение не установилось: пробуем релей.
    }

    if (!config.relayEnabled) {
      metrics.droppedDisabled += 1;
      return const RelaySendFailed(RelayFailureReason.disabled);
    }

    final attempted = <PeerId>{};
    while (true) {
      final relay = topology.selectRelay(
        source: localPeerId,
        destination: dst,
        exclude: attempted,
      );
      if (relay == null) {
        break;
      }
      attempted.add(relay.peerId);
      final frame = RelayFrame(
        dst: dst.publicKey,
        src: localPeerId.publicKey,
        ttl: config.maxHops,
        hopCount: 0,
        payload: payload,
      );
      try {
        await direct
            .send(relay.peerId, frame.toBytes())
            .timeout(config.forwardTimeout);
        metrics.relayedSent += 1;
        return RelayedSent(relay.peerId);
      } catch (_) {
        metrics.relaySendFailed += 1;
        topology.remove(relay.peerId);
      }
    }

    metrics.noRoute += 1;
    return const RelaySendFailed(RelayFailureReason.noRoute);
  }

  /// Принимает байты из входящего канала `relay`.
  ///
  /// Если кадр адресован локальному узлу — отдаёт payload в [incoming].
  /// Иначе проверяет opt-in, TTL, кэш петель, лимит источника и пересылает
  /// следующему хопу.
  Future<void> accept(PeerId from, List<int> bytes) async {
    if (_closed) {
      return;
    }
    if (bytes.length > config.maxFrameBytes) {
      metrics.droppedOversize += 1;
      return;
    }

    final RelayFrame frame;
    try {
      frame = RelayFrame.fromBytes(Uint8List.fromList(bytes));
    } catch (_) {
      metrics.droppedMalformed += 1;
      return;
    }
    if (frame.dst.length != 32 ||
        frame.src.length != 32 ||
        frame.payload.length > config.maxFrameBytes) {
      metrics.droppedMalformed += 1;
      return;
    }

    final src = PeerId(Uint8List.fromList(frame.src));
    final dst = PeerId(Uint8List.fromList(frame.dst));
    final key = _frameKey(src, dst, frame.payload);

    if (dst == localPeerId) {
      if (!_remember(key)) {
        metrics.droppedDuplicate += 1;
        return;
      }
      metrics.delivered += 1;
      if (!_incoming.isClosed) {
        _incoming.add(
          RelayInbound(
            src: src,
            payload: List<int>.unmodifiable(frame.payload),
          ),
        );
      }
      return;
    }

    if (!config.relayEnabled) {
      metrics.droppedDisabled += 1;
      return;
    }
    if (frame.ttl <= 0 || frame.hopCount >= config.maxHops) {
      metrics.droppedTtl += 1;
      return;
    }
    if (src == localPeerId) {
      metrics.droppedLoop += 1;
      return;
    }
    if (!_remember(key)) {
      metrics.droppedDuplicate += 1;
      return;
    }

    final nextHop = topology.nextHop(
      from: localPeerId,
      destination: dst,
    );
    if (nextHop == null ||
        nextHop == localPeerId ||
        nextHop == src ||
        nextHop == from) {
      metrics.droppedLoop += 1;
      return;
    }

    final bucket = _sourceBuckets.putIfAbsent(
      src,
      () => _TokenBucket(
        capacity: config.perSourceBurstBytes.toDouble(),
        refillPerSecond: config.perSourceBytesPerSecond.toDouble(),
        now: _clock(),
      ),
    );
    if (!bucket.tryConsume(
      frame.payload.length + _frameOverheadBytes,
      _clock(),
    )) {
      metrics.droppedRateLimited += 1;
      return;
    }

    try {
      await direct
          .send(nextHop, frame.forward().toBytes())
          .timeout(config.forwardTimeout);
      metrics.recordForward(src, frame.payload.length);
    } catch (_) {
      metrics.forwardFailed += 1;
      topology.remove(nextHop);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _directEvents?.cancel();
    _directEvents = null;
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  void _onDirectDone() {
    if (!_events.isClosed) {
      _events.add(const PeerLinkEvent('closed', null));
    }
  }

  bool _remember(String key) {
    final now = _clock();
    _seen.removeWhere(
      (_, at) => now.difference(at) > config.seenTtl,
    );
    if (_seen.containsKey(key)) {
      return false;
    }
    if (_seen.length >= config.seenMaxEntries) {
      _seen.remove(_seen.keys.first);
    }
    _seen[key] = now;
    return true;
  }

  String _frameKey(PeerId src, PeerId dst, List<int> payload) {
    final hasher = sha256.convert(<int>[
      ...src.publicKey,
      ...dst.publicKey,
      ...payload,
    ]);
    return hasher.toString();
  }
}

const int _frameOverheadBytes = 64;

class _TokenBucket {
  _TokenBucket({
    required this.capacity,
    required this.refillPerSecond,
    required DateTime now,
  }) : _tokens = capacity,
       _last = now;

  final double capacity;
  final double refillPerSecond;
  double _tokens;
  DateTime _last;

  bool tryConsume(int amount, DateTime now) {
    final elapsed = now.difference(_last).inMicroseconds / 1000000;
    if (elapsed > 0) {
      _tokens = min(capacity, _tokens + elapsed * refillPerSecond);
      _last = now;
    }
    if (_tokens < amount) {
      return false;
    }
    _tokens -= amount;
    return true;
  }
}
