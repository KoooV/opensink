import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide RelayFrame;
import 'package:core_protocol/core_protocol.dart' show RelayFrame;
import 'package:cryptography/cryptography.dart' show Sha256;
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
    _incoming = StreamController<RelayInbound>.broadcast(
      onListen: _flushBufferedInbound,
    );
    _directEvents = direct.events.listen(
      _onDirectEvent,
      onError: _onDirectError,
      onDone: _onDirectDone,
    );
    _relayEvents = direct.relayIncoming.listen(
      (datagram) {
        if (!_closed) {
          unawaited(accept(datagram.from, datagram.bytes));
        }
      },
      onError: _onDirectError,
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
  late final StreamController<RelayInbound> _incoming;
  final List<RelayInbound> _incomingBuffer = <RelayInbound>[];
  final Sha256 _sha256 = Sha256();

  final Map<String, DateTime> _seen = <String, DateTime>{};
  final Set<String> _inFlight = <String>{};
  final LinkedHashMap<PeerId, _TokenBucket> _sourceBuckets =
      LinkedHashMap<PeerId, _TokenBucket>();

  StreamSubscription<PeerLinkEvent>? _directEvents;
  StreamSubscription<RelayDatagram>? _relayEvents;
  bool _closed = false;

  /// Входящие payload'ы, дошедшие через релей.
  ///
  /// До первой подписки кадры буферизуются (не более
  /// [RelayConfig.incomingBufferFrames]); при переполнении новые кадры
  /// отбрасываются.
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
        topology.disableRelay(relay.peerId);
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

    final key = await _frameKey(src, dst, frame.nonce);
    _pruneSeen();
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
        final queued = _enqueueInbound(
          RelayInbound(
            src: src,
            payload: List<int>.unmodifiable(frame.payload),
          ),
        );
        if (!queued) {
          return;
        }
        metrics.delivered += 1;
        _remember(key);
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

      final attempted = <PeerId>{};
      while (true) {
        final nextHop = topology.nextHop(
          from: localPeerId,
          destination: dst,
          exclude: attempted,
        );
        if (nextHop == null ||
            nextHop == localPeerId ||
            nextHop == src ||
            nextHop == from) {
          if (attempted.isEmpty) {
            metrics.droppedLoop += 1;
          } else {
            metrics.forwardExhausted += 1;
          }
          return;
        }
        if (!attempted.add(nextHop)) {
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
          return;
        } catch (_) {
          metrics.forwardFailed += 1;
          if (nextHop != dst) {
            topology.disableRelay(nextHop);
          }
        }
      }
    } finally {
      _inFlight.remove(key);
    }
  }

  @override
  Future<void> close() => _shutdown(closeDirect: true);

  Future<void> _shutdown({required bool closeDirect}) async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _directEvents?.cancel();
    _directEvents = null;
    await _relayEvents?.cancel();
    _relayEvents = null;
    _incomingBuffer.clear();
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
    if (!_events.isClosed) {
      await _events.close();
    }
    if (closeDirect) {
      await direct.close();
    }
  }

  void _onDirectEvent(PeerLinkEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _onDirectError(Object error, StackTrace stackTrace) {
    if (!_events.isClosed) {
      _events.addError(error, stackTrace);
    }
  }

  void _onDirectDone() {
    unawaited(_shutdown(closeDirect: false));
  }

  bool _enqueueInbound(RelayInbound inbound) {
    if (_incoming.isClosed) {
      return false;
    }
    if (_incoming.hasListener) {
      _incoming.add(inbound);
      return true;
    }
    if (config.incomingBufferFrames <= 0 ||
        _incomingBuffer.length >= config.incomingBufferFrames) {
      metrics.droppedInboundOverflow += 1;
      return false;
    }
    _incomingBuffer.add(inbound);
    return true;
  }

  void _flushBufferedInbound() {
    if (_incomingBuffer.isEmpty) {
      return;
    }
    final pending = List<RelayInbound>.of(_incomingBuffer);
    _incomingBuffer.clear();
    for (final inbound in pending) {
      if (_incoming.isClosed) {
        return;
      }
      _incoming.add(inbound);
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
    _pruneSeen();
    if (_seen.containsKey(key)) {
      return false;
    }
    while (_seen.length >= config.seenMaxEntries) {
      _seen.remove(_seen.keys.first);
    }
    _seen[key] = _clock();
    return true;
  }

  void _pruneSeen() {
    if (config.seenMaxEntries <= 0) {
      return;
    }
    final now = _clock();
    _seen.removeWhere((_, at) => now.difference(at) > config.seenTtl);
  }

  Uint8List _nonce() {
    return Uint8List.fromList(
      List<int>.generate(16, (_) => _random.nextInt(256)),
    );
  }

  Future<String> _frameKey(PeerId src, PeerId dst, List<int> nonce) async {
    final hash = await _sha256.hash(<int>[
      ...src.publicKey,
      ...dst.publicKey,
      ...nonce,
    ]);
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
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
