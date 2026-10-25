import 'dart:async';

import 'package:core_domain/core_domain.dart';

import 'expiring_set.dart';
import 'signaling_types.dart';
import 'signaling_utils.dart';

/// Объединяет несколько [RichSignalingChannel] (например, Nostr + трекеры)
/// в один канал: публикация во все, входящие — с дедупликацией.
class SignalingChannelPool implements RichSignalingChannel, NeighborAnnouncer {
  SignalingChannelPool({
    required Iterable<RichSignalingChannel> channels,
    Duration dedupeTtl = const Duration(minutes: 5),
    Duration presenceDedupeTtl = const Duration(milliseconds: 750),
    DateTime Function()? clock,
  }) : channels = List<RichSignalingChannel>.unmodifiable(channels),
       _seenPackets = ExpiringSet(
         ttl: dedupeTtl,
         maxEntries: 10000,
         clock: clock,
       ),
       _seenPresence = ExpiringSet(
         ttl: presenceDedupeTtl,
         maxEntries: 10000,
         clock: clock,
       ) {
    for (final channel in this.channels) {
      _subscriptions.add(channel.packets.listen(_onPacket));
      _subscriptions.add(channel.presence.listen(_onPresence));
    }
  }

  final List<RichSignalingChannel> channels;

  final ExpiringSet _seenPackets;
  final ExpiringSet _seenPresence;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  final StreamController<SignalingPacket> _packets =
      StreamController<SignalingPacket>.broadcast();
  final StreamController<PeerPresence> _presence =
      StreamController<PeerPresence>.broadcast();

  late final Stream<SignalingMessage> _incoming = _packets.stream.map(
    (packet) => SignalingMessage(
      topic: packet.topic,
      bytes: packet.bytes,
      from: packet.from,
      timestamp: packet.timestamp,
    ),
  );

  bool _closed = false;

  @override
  Stream<SignalingMessage> get incoming => _incoming;

  @override
  Stream<SignalingPacket> get packets => _packets.stream;

  @override
  Stream<PeerPresence> get presence => _presence.stream;

  @override
  Future<void> join(String topic) async {
    if (_closed) {
      throw StateError('SignalingChannelPool is closed');
    }
    await Future.wait(
      channels.map(
        (channel) => _ignoreChannelFailure(() => channel.join(topic)),
      ),
    );
  }

  @override
  Future<void> publish(String topic, List<int> bytes) =>
      publishTo(topic, kind: SignalingKind.data, bytes: bytes);

  @override
  Future<void> publishTo(
    String topic, {
    required SignalingKind kind,
    PeerId? to,
    required List<int> bytes,
  }) async {
    if (_closed) {
      throw StateError('SignalingChannelPool is closed');
    }
    await Future.wait(
      channels.map(
        (channel) => _ignoreChannelFailure(
          () => channel.publishTo(topic, kind: kind, to: to, bytes: bytes),
        ),
      ),
    );
  }

  @override
  Future<void> updateNeighbors(Iterable<PeerId> neighbors) async {
    if (_closed) {
      throw StateError('SignalingChannelPool is closed');
    }
    final snapshot = List<PeerId>.unmodifiable(neighbors);
    await Future.wait(
      channels.whereType<NeighborAnnouncer>().map(
        (channel) =>
            _ignoreChannelFailure(() => channel.updateNeighbors(snapshot)),
      ),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final subscription in _subscriptions) {
      await _ignoreChannelFailure(subscription.cancel);
    }
    _subscriptions.clear();
    for (final channel in channels) {
      await _ignoreChannelFailure(channel.close);
    }
    await _packets.close();
    await _presence.close();
  }

  /// Один сбойный backend не должен блокировать остальные каналы пула.
  Future<void> _ignoreChannelFailure(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Ошибка изолирована на уровне канала; health доступен в самом канале.
    }
  }

  void _onPacket(SignalingPacket packet) {
    final recipient = packet.to == null
        ? ''
        : bytesToBinaryString(packet.to!.publicKey);
    final key =
        '${packet.topic}:${packet.kind.name}:'
        '${bytesToBinaryString(packet.from.publicKey)}:$recipient:'
        '${sha256Hex(packet.bytes)}';
    if (!_seenPackets.add(key) || _packets.isClosed) {
      return;
    }
    _packets.add(packet);
  }

  void _onPresence(PeerPresence value) {
    final key = '${value.topic}:${bytesToBinaryString(value.peerId.publicKey)}';
    if (!_seenPresence.add(key) || _presence.isClosed) {
      return;
    }
    _presence.add(value);
  }
}
