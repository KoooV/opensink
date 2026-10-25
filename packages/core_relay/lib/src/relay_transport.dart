import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide RelayFrame;
import 'package:core_protocol/core_protocol.dart' show RelayFrame;
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import 'relay_config.dart';
import 'relay_envelope.dart';
import 'relay_frame_auth.dart';
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
    required this.signer,
    this.config = const RelayConfig(),
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure(),
       metrics = RelayMetrics(maxTrackedSources: config.maxTrackedSources) {
    _directEvents = direct.events.listen(
      _events.add,
      onError: _events.addError,
      onDone: _onDirectDone,
    );
    _relayEvents = direct.relayIncoming.listen(
      (datagram) {
        unawaited(accept(datagram.from, datagram.bytes));
      },
      onError: _events.addError,
    );
  }

  final PeerId localPeerId;

  /// Транспорт прямых соединений (core_peer).
  final Transport direct;

  final RelayTopology topology;
  final Signer signer;
  final RelayConfig config;
  final DateTime Function() _clock;
  final Random _random;

  final RelayMetrics metrics;
  final StreamController<PeerLinkEvent> _events =
      StreamController<PeerLinkEvent>.broadcast();
  final StreamController<RelayInbound> _incoming =
      StreamController<RelayInbound>.broadcast();

  final Map<String, DateTime> _seen = <String, DateTime>{};
  final Set<String> _inFlight = <String>{};
  final LinkedHashMap<PeerId, _TokenBucket> _sourceBuckets =
      LinkedHashMap<PeerId, _TokenBucket>();

  StreamSubscription<PeerLinkEvent>? _directEvents;
  StreamSubscription<RelayDatagram>? _relayEvents;
  bool _closed = false;

  /// Входящие payload'ы, дошедшие через релей.
  Stream<RelayInbound> get incoming => _incoming.stream;

  /// Сколько источников сейчас учитывается в token bucket (для тестов).
  @visibleForTesting
  int get trackedSourceCount => _sourceBuckets.length;

  @override
  Stream<PeerLinkEvent> get events => _events.stream;

  @override
  Stream<RelayDatagram> get relayIncoming => direct.relayIncoming;

  @override
  Future<PeerLink> connect(PeerId peerId) => direct.connect(peerId);

  @override
  Future<void> send(PeerId dst, List<int> bytes) async {
    final result = await deliver(dst, bytes);
    if (result is RelaySendFailed) {
      throw StateError('relay send failed: ${result.reason.name}');
    }
  }

  @override
  Future<void> sendRelay(PeerId dst, List<int> bytes) =>
      direct.sendRelay(dst, bytes);

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
    if (payload.length > config.maxPayloadBytes) {
      metrics.droppedOversize += 1;
      return const RelaySendFailed(RelayFailureReason.frameTooLarge);
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
        nonce: _nonce(),
      );
      final signature = await RelayFrameAuth.sign(frame, signer);
      final encoded = RelayEnvelope.encode(
        frame.copyWith(signature: signature),
      );
      if (encoded.length > config.maxFrameBytes) {
        metrics.droppedOversize += 1;
        return const RelaySendFailed(RelayFailureReason.frameTooLarge);
      }
      try {
        await direct
            .sendRelay(relay.peerId, encoded)
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

    // Лимит и ключевание по аутентифицированному соседу `from` — до парсинга
    // и хэширования payload.
    final bucket = _bucketFor(from);
    if (bucket != null && !bucket.tryConsume(bytes.length, _clock())) {
      metrics.droppedRateLimited += 1;
      return;
    }

    final frame = RelayEnvelope.decode(Uint8List.fromList(bytes));
    if (frame == null) {
      metrics.droppedMalformed += 1;
      return;
    }
    if (frame.dst.length != 32 ||
        frame.src.length != 32 ||
        frame.payload.length > config.maxPayloadBytes ||
        frame.nonce.length != 16 ||
        frame.signature.length != 64) {
      metrics.droppedMalformed += 1;
      return;
    }

    final src = PeerId(Uint8List.fromList(frame.src));
    final dst = PeerId(Uint8List.fromList(frame.dst));

    if (src == localPeerId) {
      metrics.droppedLoop += 1;
      return;
    }
    // На первом хопе `src` обязан совпадать с прямым отправителем. Дальше
    // `src` сохраняется как origin и проверяется e2e-слоем.
    if (frame.hopCount == 0 && src != from) {
      metrics.droppedUnauthenticated += 1;
      return;
    }
    final originTtl = frame.ttl + frame.hopCount;
    if (originTtl > config.maxHops) {
      metrics.droppedTtl += 1;
      return;
    }
    if (!await RelayFrameAuth.verify(frame, src, signer)) {
      metrics.droppedBadSignature += 1;
      return;
    }

    final key = _frameKey(src, dst, frame.nonce);
    if (_seen.containsKey(key)) {
      metrics.droppedDuplicate += 1;
      return;
    }
    if (!_inFlight.add(key)) {
      metrics.droppedDuplicate += 1;
      return;
    }

    try {
      if (dst == localPeerId) {
        metrics.delivered += 1;
        _remember(key);
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

      final forwarded = frame
          .copyWith(unknownFields: const <int, Uint8List>{})
          .forward();
      final encoded = RelayEnvelope.encode(forwarded);
      if (encoded.length > config.maxFrameBytes) {
        metrics.droppedOversize += 1;
        return;
      }

      try {
        await direct
            .sendRelay(nextHop, encoded)
            .timeout(config.forwardTimeout);
        metrics.recordForward(from, encoded.length);
        _remember(key);
      } catch (_) {
        metrics.forwardFailed += 1;
        topology.remove(nextHop);
      }
    } finally {
      _inFlight.remove(key);
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
    await _relayEvents?.cancel();
    _relayEvents = null;
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

  _TokenBucket? _bucketFor(PeerId source) {
    if (config.maxSourceEntries <= 0) {
      return null;
    }
    final existing = _sourceBuckets.remove(source);
    if (existing != null) {
      _sourceBuckets[source] = existing;
      return existing;
    }
    final created = _TokenBucket(
      capacity: config.perSourceBurstBytes.toDouble(),
      refillPerSecond: config.perSourceBytesPerSecond.toDouble(),
      now: _clock(),
    );
    _sourceBuckets[source] = created;
    while (_sourceBuckets.length > config.maxSourceEntries) {
      _sourceBuckets.remove(_sourceBuckets.keys.first);
    }
    return created;
  }

  bool _remember(String key) {
    if (config.seenMaxEntries <= 0) {
      return true;
    }
    final now = _clock();
    _seen.removeWhere(
      (_, at) => now.difference(at) > config.seenTtl,
    );
    if (_seen.containsKey(key)) {
      return false;
    }
    while (_seen.length >= config.seenMaxEntries) {
      _seen.remove(_seen.keys.first);
    }
    _seen[key] = now;
    return true;
  }

  Uint8List _nonce() {
    return Uint8List.fromList(
      List<int>.generate(16, (_) => _random.nextInt(256)),
    );
  }

  String _frameKey(PeerId src, PeerId dst, List<int> nonce) {
    final hasher = sha256.convert(<int>[
      ...src.publicKey,
      ...dst.publicKey,
      ...nonce,
    ]);
    return hasher.toString();
  }
}

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
