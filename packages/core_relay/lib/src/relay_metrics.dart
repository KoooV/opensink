import 'dart:collection';

import 'package:core_domain/core_domain.dart';

/// Счётчики релейного слоя. Сбрасываются только вместе с транспортом.
class RelayMetrics {
  RelayMetrics({this.maxTrackedSources = 256});

  /// Предел числа источников в [forwardedBytesBySource].
  final int maxTrackedSources;

  int directSent = 0;
  int directFailed = 0;
  int relayedSent = 0;
  int relaySendFailed = 0;
  int delivered = 0;
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
  int noRoute = 0;

  final LinkedHashMap<PeerId, int> forwardedBytesBySource =
      LinkedHashMap<PeerId, int>();

  void recordForward(PeerId source, int bytes) {
    forwarded += 1;
    forwardedBytes += bytes;
    forwardedBytesBySource.remove(source);
    forwardedBytesBySource[source] =
        (forwardedBytesBySource[source] ?? 0) + bytes;
    while (maxTrackedSources > 0 &&
        forwardedBytesBySource.length > maxTrackedSources) {
      forwardedBytesBySource.remove(forwardedBytesBySource.keys.first);
    }
    if (maxTrackedSources <= 0) {
      forwardedBytesBySource.clear();
    }
  }

  @override
  String toString() =>
      'RelayMetrics(direct=$directSent/$directFailed, forwarded=$forwarded, '
      'delivered=$delivered, '
      'duplicate=$droppedDuplicate, ttl=$droppedTtl, disabled=$droppedDisabled, '
      'rate=$droppedRateLimited, oversize=$droppedOversize, '
      'malformed=$droppedMalformed, loop=$droppedLoop, '
      'unauthenticated=$droppedUnauthenticated, '
      'badSignature=$droppedBadSignature, noRoute=$noRoute, '
      'forwardFailed=$forwardFailed, forwardExhausted=$forwardExhausted)';
}
