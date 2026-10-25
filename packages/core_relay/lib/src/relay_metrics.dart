import 'dart:collection';
import 'dart:math';

import 'package:core_domain/core_domain.dart';

/// Счётчики релейного слоя. Сбрасываются только вместе с транспортом.
class RelayMetrics {
  RelayMetrics({
    this.maxTrackedSources = 256,
    this.loadWindow = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Предел числа источников в [forwardedBytesBySource].
  final int maxTrackedSources;

  /// Окно усреднения наблюдаемой нагрузки.
  final Duration loadWindow;

  final DateTime Function() _clock;
  final Map<PeerId, _ForwardWindow> _loadWindows = <PeerId, _ForwardWindow>{};

  int directSent = 0;
  int directFailed = 0;
  int relayedSent = 0;
  int relaySendFailed = 0;
  int delivered = 0;
  int queuedInbound = 0;
  int forwarded = 0;
  int forwardedBytes = 0;
  int forwardFailed = 0;
  int forwardExhausted = 0;
  int droppedDuplicate = 0;
  int droppedTtl = 0;
  int droppedDisabled = 0;
  int droppedRateLimited = 0;
  int droppedOversize = 0;
  int droppedMalformed = 0;
  int droppedLoop = 0;
  int droppedUnauthenticated = 0;
  int droppedBadSignature = 0;
  int droppedInboundOverflow = 0;
  int droppedInboundNoBuffer = 0;
  int droppedInboundClosed = 0;
  int droppedSeenFull = 0;
  int acceptFailed = 0;
  int shutdownFailed = 0;
  int noRoute = 0;

  final LinkedHashMap<PeerId, int> forwardedBytesBySource =
      LinkedHashMap<PeerId, int>();

  void recordForward(PeerId source, int bytes) {
    forwarded += 1;
    forwardedBytes += bytes;
    forwardedBytesBySource.remove(source);
    forwardedBytesBySource[source] =
        (forwardedBytesBySource[source] ?? 0) + bytes;

    final now = _clock();
    final window = _loadWindows[source];
    if (window == null || now.difference(window.startedAt) >= loadWindow) {
      _loadWindows[source] = _ForwardWindow(now, bytes);
    } else {
      window.bytes += bytes;
    }

    while (maxTrackedSources > 0 &&
        forwardedBytesBySource.length > maxTrackedSources) {
      final evicted = forwardedBytesBySource.keys.first;
      forwardedBytesBySource.remove(evicted);
      _loadWindows.remove(evicted);
    }
    if (maxTrackedSources <= 0) {
      forwardedBytesBySource.clear();
      _loadWindows.clear();
    }
  }

  /// Наблюдаемая скорость пересылки от [source], байт/с.
  ///
  /// Локальная оценка нагрузки: сколько этот узел присылал нам в пределах
  /// [loadWindow]. Удалённую нагрузку релея presence-кодек не передаёт.
  int observedLoadBytesPerSecond(PeerId source) {
    final window = _loadWindows[source];
    if (window == null) {
      return 0;
    }
    final elapsed = _clock().difference(window.startedAt);
    if (elapsed >= loadWindow || elapsed.isNegative) {
      return 0;
    }
    final seconds = max(elapsed.inMicroseconds / 1000000, 1.0);
    return (window.bytes / seconds).round();
  }

  @override
  String toString() =>
      'RelayMetrics(direct=$directSent/$directFailed, forwarded=$forwarded, '
      'delivered=$delivered, queued=$queuedInbound, '
      'duplicate=$droppedDuplicate, ttl=$droppedTtl, disabled=$droppedDisabled, '
      'rate=$droppedRateLimited, oversize=$droppedOversize, '
      'malformed=$droppedMalformed, loop=$droppedLoop, '
      'unauthenticated=$droppedUnauthenticated, '
      'badSignature=$droppedBadSignature, '
      'inboundOverflow=$droppedInboundOverflow, '
      'inboundNoBuffer=$droppedInboundNoBuffer, '
      'inboundClosed=$droppedInboundClosed, '
      'seenFull=$droppedSeenFull, acceptFailed=$acceptFailed, '
      'shutdownFailed=$shutdownFailed, noRoute=$noRoute, '
      'forwardFailed=$forwardFailed, forwardExhausted=$forwardExhausted)';
}

class _ForwardWindow {
  _ForwardWindow(this.startedAt, this.bytes);

  final DateTime startedAt;
  int bytes;
}
