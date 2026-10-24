import 'package:core_domain/core_domain.dart';

/// Счётчики релейного слоя. Сбрасываются только вместе с транспортом.
class RelayMetrics {
  int directSent = 0;
  int directFailed = 0;
  int relayedSent = 0;
  int relaySendFailed = 0;
  int delivered = 0;
  int forwarded = 0;
  int forwardedBytes = 0;
  int forwardFailed = 0;
  int droppedDuplicate = 0;
  int droppedTtl = 0;
  int droppedDisabled = 0;
  int droppedRateLimited = 0;
  int droppedOversize = 0;
  int droppedMalformed = 0;
  int droppedLoop = 0;
  int noRoute = 0;

  final Map<PeerId, int> forwardedBytesBySource = <PeerId, int>{};

  void recordForward(PeerId source, int bytes) {
    forwarded += 1;
    forwardedBytes += bytes;
    forwardedBytesBySource[source] =
        (forwardedBytesBySource[source] ?? 0) + bytes;
  }

  @override
  String toString() =>
      'RelayMetrics(direct=$directSent/$directFailed, forwarded=$forwarded, '
      'delivered=$delivered, '
      'duplicate=$droppedDuplicate, ttl=$droppedTtl, disabled=$droppedDisabled, '
      'rate=$droppedRateLimited, oversize=$droppedOversize, '
      'malformed=$droppedMalformed, loop=$droppedLoop, noRoute=$noRoute, '
      'forwardFailed=$forwardFailed)';
}
