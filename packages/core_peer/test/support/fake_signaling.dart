import 'dart:async';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_signaling/core_signaling.dart';

/// In-memory signaling layer 5: маршрутизирует [SignalingPacket] по topic и to.
class FakeSignalingBus {
  final List<FakeRichSignalingChannel> channels = <FakeRichSignalingChannel>[];

  FakeRichSignalingChannel create(PeerId peerId) {
    final channel = FakeRichSignalingChannel(peerId, this);
    channels.add(channel);
    return channel;
  }

  void route(SignalingPacket packet) {
    for (final channel in List<FakeRichSignalingChannel>.of(channels)) {
      if (channel.peerId == packet.from) {
        continue;
      }
      if (channel.isClosed) {
        continue;
      }
      if (!channel.joinedTopics.contains(packet.topic)) {
        continue;
      }
      final to = packet.to;
      if (to != null && to != channel.peerId) {
        continue;
      }
      channel.deliver(packet);
    }
  }
}

class FakeRichSignalingChannel implements RichSignalingChannel {
  FakeRichSignalingChannel(this.peerId, this._bus);

  final PeerId peerId;
  final FakeSignalingBus _bus;
  final Set<String> joinedTopics = <String>{};

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

  bool isClosed = false;

  @override
  Stream<SignalingMessage> get incoming => _incoming;

  @override
  Stream<SignalingPacket> get packets => _packets.stream;

  @override
  Stream<PeerPresence> get presence => _presence.stream;

  @override
  Future<void> join(String topic) async {
    joinedTopics.add(topic);
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
    if (isClosed) {
      throw StateError('FakeRichSignalingChannel is closed');
    }
    final packet = SignalingPacket(
      topic: topic,
      kind: kind,
      from: peerId,
      to: to,
      bytes: Uint8List.fromList(bytes),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await Future<void>.microtask(() => _bus.route(packet));
  }

  void deliver(SignalingPacket packet) {
    if (!_packets.isClosed) {
      _packets.add(packet);
    }
  }

  @override
  Future<void> close() async {
    if (isClosed) {
      return;
    }
    isClosed = true;
    await _packets.close();
    await _presence.close();
  }
}
