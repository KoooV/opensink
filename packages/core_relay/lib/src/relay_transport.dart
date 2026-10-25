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
    this.initialLocalNeighbors = const <PeerId>[],
    this.linkStats,
    DateTime Function()? clock,
    Duration Function()? monotonicClock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _monotonicClock = monotonicClock,
       _random = random ?? Random.secure(),
       metrics = RelayMetrics(
         maxTrackedSources: config.maxTrackedSources,
         clock: clock ?? DateTime.now,
       ) {
    topology.setLocalPeer(localPeerId);
    topology.seedLocalNeighbors(initialLocalNeighbors);
    _incoming = StreamController<RelayInbound>.broadcast(
      onListen: _scheduleFlush,
    );
    _directEvents = direct.events.listen(
      _onDirectEvent,
      onError: _onDirectError,
      onDone: _onDirectDone,
    );
    _relayEvents = direct.relayIncoming.listen((datagram) {
      if (!_closed) {
        unawaited(
          accept(datagram.from, datagram.bytes).catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            metrics.acceptFailed += 1;
          }),
        );
      }
    }, onError: _onDirectError);
  }

  final PeerId localPeerId;

  /// Транспорт прямых соединений (core_peer).
  final Transport direct;

  final RelayTopology topology;
  final Signer signer;
  final RelayConfig config;

  /// Линки, установленные до создания транспорта.
  final Iterable<PeerId> initialLocalNeighbors;

  /// Локальная статистика прямого линка (RTT, битрейт).
  final PeerLinkStats? Function(PeerId peerId)? linkStats;

  final DateTime Function() _clock;
  final Duration Function()? _monotonicClock;
  final Stopwatch _monotonicWatch = Stopwatch()..start();
  final Random _random;

  final RelayMetrics metrics;
  final StreamController<PeerLinkEvent> _events =
      StreamController<PeerLinkEvent>.broadcast();
  late final StreamController<RelayInbound> _incoming;
  final List<RelayInbound> _incomingBuffer = <RelayInbound>[];
  final Sha256 _sha256 = Sha256();

  final Map<String, Duration> _seen = <String, Duration>{};
  final Set<String> _inFlight = <String>{};
  final LinkedHashMap<PeerId, _TokenBucket> _sourceBuckets =
      LinkedHashMap<PeerId, _TokenBucket>();

  StreamSubscription<PeerLinkEvent>? _directEvents;
  StreamSubscription<RelayDatagram>? _relayEvents;
  Future<void>? _closing;
  bool _directClosed = false;
  bool _flushing = false;
  bool _closed = false;

  /// Входящие payload'ы, дошедшие через релей.
  ///
  /// Пока у потока нет слушателей, кадры буферизуются (не более
  /// [RelayConfig.incomingBufferFrames]); при переполнении новые кадры
  /// отбрасываются. После отмены последнего слушателя буфер снова активен.
  Stream<RelayInbound> get incoming => _incoming.stream;

  Duration _now() => _monotonicClock?.call() ?? _monotonicWatch.elapsed;

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
      if (_closed) {
        return const RelaySendFailed(RelayFailureReason.closed);
      }
      metrics.directSent += 1;
      return const DirectSent();
    } catch (_) {
      if (_closed) {
        return const RelaySendFailed(RelayFailureReason.closed);
      }
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

    _observeTopology();
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
      if (_closed) {
        return const RelaySendFailed(RelayFailureReason.closed);
      }
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
        if (_closed) {
          return const RelaySendFailed(RelayFailureReason.closed);
        }
        metrics.relayedSent += 1;
        return RelayedSent(relay.peerId);
      } catch (_) {
        if (_closed) {
          return const RelaySendFailed(RelayFailureReason.closed);
        }
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
    if (_closed) {
      return;
    }

    final key = await _frameKey(src, dst, frame.nonce);
    if (_closed) {
      return;
    }
    _pruneSeen();
    if (_seen.containsKey(key)) {
      metrics.droppedDuplicate += 1;
      return;
    }
    if (!_inFlight.add(key)) {
      metrics.droppedDuplicate += 1;
      return;
    }

    var reserved = false;
    var committed = false;
    try {
      // Запись резервируется до доставки, чтобы при полном кэше отбросить
      // новый кадр, а не вытеснить ещё не истёкший nonce (R-22).
      if (!_remember(key)) {
        metrics.droppedSeenFull += 1;
        return;
      }
      reserved = true;

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
        committed = true;
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

      _observeTopology();
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
          if (_closed) {
            return;
          }
          metrics.recordForward(from, encoded.length);
          committed = true;
          return;
        } catch (_) {
          if (_closed) {
            return;
          }
          metrics.forwardFailed += 1;
          if (nextHop != dst) {
            topology.disableRelay(nextHop);
          }
        }
      }
    } finally {
      _inFlight.remove(key);
      if (reserved && !committed) {
        _seen.remove(key);
      }
    }
  }

  @override
  Future<void> close() async {
    try {
      final pending = _closing ??= _shutdown();
      await pending;
    } finally {
      await _closeDirectOnce();
    }
  }

  Future<void> _closeDirectOnce() async {
    if (_directClosed) {
      return;
    }
    _directClosed = true;
    await direct.close();
  }

  Future<void> _shutdown() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _directEvents?.cancel();
    _directEvents = null;
    await _relayEvents?.cancel();
    _relayEvents = null;
    if (_incomingBuffer.isNotEmpty) {
      metrics.droppedInboundClosed += _incomingBuffer.length;
      _incomingBuffer.clear();
    }
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  /// Обновляет RTT/нагрузку в presence-графе локальными измерениями.
  void _observeTopology() {
    for (final peerId in topology.knownPeerIds) {
      final stats = linkStats?.call(peerId);
      final measuredRtt = stats != null && stats.rtt > Duration.zero
          ? stats.rtt
          : null;
      final load = metrics.observedLoadBytesPerSecond(peerId);
      if (measuredRtt == null && load <= 0) {
        continue;
      }
      topology.observeLink(
        peerId,
        rtt: measuredRtt,
        loadBytesPerSecond: load > 0 ? load : null,
      );
    }
  }

  void _onDirectEvent(PeerLinkEvent event) {
    final peerId = event.peerId;
    if (peerId != null) {
      if (event.type == 'connected') {
        topology.addLocalNeighbor(peerId);
      } else if (event.type == 'disconnected' || event.type == 'error') {
        topology.removeLocalNeighbor(peerId);
      }
    }
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
    _closing ??= _shutdown().catchError((Object error, StackTrace stackTrace) {
      metrics.shutdownFailed += 1;
    });
  }

  bool _enqueueInbound(RelayInbound inbound) {
    if (_closed || _incoming.isClosed) {
      metrics.droppedInboundClosed += 1;
      return false;
    }
    if (_incoming.hasListener && _incomingBuffer.isEmpty) {
      _incoming.add(inbound);
      metrics.delivered += 1;
      return true;
    }
    if (config.incomingBufferFrames <= 0) {
      metrics.droppedInboundNoBuffer += 1;
      return false;
    }
    if (_incomingBuffer.length >= config.incomingBufferFrames) {
      metrics.droppedInboundOverflow += 1;
      return false;
    }
    _incomingBuffer.add(inbound);
    metrics.queuedInbound += 1;
    _scheduleFlush();
    return true;
  }

  void _scheduleFlush() {
    if (_flushing ||
        _closed ||
        !_incoming.hasListener ||
        _incomingBuffer.isEmpty) {
      return;
    }
    unawaited(_flushBufferedInbound());
  }

  Future<void> _flushBufferedInbound() async {
    if (_flushing) {
      return;
    }
    _flushing = true;
    try {
      while (!_closed &&
          !_incoming.isClosed &&
          _incoming.hasListener &&
          _incomingBuffer.isNotEmpty) {
        final inbound = _incomingBuffer.removeAt(0);
        try {
          _incoming.add(inbound);
          metrics.delivered += 1;
        } catch (_) {
          metrics.droppedInboundClosed += 1;
          break;
        }
        // Даём отмене подписки (например, `.first`) примениться до
        // следующего кадра, чтобы неотданные кадры остались в буфере.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _flushing = false;
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
    if (_seen.length >= config.seenMaxEntries) {
      return false;
    }
    _seen[key] = _now();
    return true;
  }

  void _pruneSeen() {
    if (config.seenMaxEntries <= 0) {
      return;
    }
    final now = _now();
    _seen.removeWhere((_, at) => now - at > config.seenTtl);
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
