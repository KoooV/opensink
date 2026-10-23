import 'dart:async';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_peer/core_peer.dart';
import 'package:core_peer/core_peer_flutter.dart';
import 'package:core_signaling/core_signaling.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Реальный WebRTC (flutter_webrtc) на native Linux/Android со слоем signaling 5.
///
/// Запуск:
///   cd apps/app
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/peer_link_native_test.dart -d linux
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/peer_link_native_test.dart -d emulator-5554
const _runChaos = bool.fromEnvironment('PEER_CHAOS', defaultValue: true);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real WebRTC: connect, exchange all channels, ICE restart, close',
    () async {
      final pair = _Pair();
      addTearDown(pair.close);
      await pair.start();

      final linkA = await _stage(
        'connect',
        pair.transportA.connect(pair.peerB),
      );
      expect(linkA.state, PeerLinkState.connected);
      final linkB = await pair.remoteLink();

      await _expectRoundTrip(
        'control',
        linkA,
        linkB,
        pair.transportA,
        pair.transportB,
        pair.peerA,
        pair.peerB,
        const <int>[1, 2, 3, 4],
        const <int>[5, 6],
      );
      await _expectDirection(
        'sync',
        linkA,
        linkB,
        pair.transportA,
        pair.peerB,
        const <int>[10, 11],
      );
      await _expectDirection(
        'file',
        linkA,
        linkB,
        pair.transportA,
        pair.peerB,
        const <int>[12, 13, 14],
      );

      await _stage(
        'stats',
        _waitUntil(
          () => linkA.stats.bytesSent > 0 && linkA.stats.rtt > Duration.zero,
          timeout: const Duration(seconds: 30),
          reason: 'real getStats returns RTT and byte counters',
        ),
      );

      pair.transportA.notifyNetworkChanged();
      await _stage(
        'afterRestart',
        _waitUntil(
          () => linkA.state == PeerLinkState.connected,
          timeout: const Duration(seconds: 20),
          reason: 'real link reconnected after ICE restart',
        ),
      );
      final afterRestart = linkB.incoming
          .firstWhere((incoming) => incoming.channel == PeerChannels.control)
          .timeout(const Duration(seconds: 30));
      await _stage(
        'sendAfterRestart',
        pair.transportA.send(pair.peerB, const <int>[7]),
      );
      expect(
        (await _stage('recvAfterRestart', afterRestart)).bytes,
        const <int>[7],
      );

      final closedOnB = linkB.stateStream
          .firstWhere((state) => state == PeerLinkState.closed)
          .timeout(const Duration(seconds: 30));
      await _stage('closeA', pair.transportA.close());
      await _stage('closedOnB', closedOnB);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'real WebRTC glare: simultaneous connect converges and stays usable',
    skip: _runChaos ? false : 'PEER_CHAOS=false',
    () async {
      final pair = _Pair();
      addTearDown(pair.close);
      await pair.start();

      final links = await _stage(
        'simultaneousConnect',
        Future.wait<PeerLink>([
          pair.transportA.connect(pair.peerB),
          pair.transportB.connect(pair.peerA),
        ]),
      );
      expect(links[0].state, PeerLinkState.connected);
      expect(links[1].state, PeerLinkState.connected);

      await _expectDirection(
        PeerChannels.sync,
        links[0],
        links[1],
        pair.transportA,
        pair.peerB,
        const <int>[21],
      );
      await _expectDirection(
        PeerChannels.sync,
        links[1],
        links[0],
        pair.transportB,
        pair.peerA,
        const <int>[22],
      );

      final closedOnB = links[1].stateStream
          .firstWhere((state) => state == PeerLinkState.closed)
          .timeout(const Duration(seconds: 30));
      await _stage('closeA', pair.transportA.close());
      await _stage('closedOnB', closedOnB);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'real WebRTC reconnect: survives PeerConnection failure',
    skip: _runChaos ? false : 'PEER_CHAOS=false',
    () async {
      final recording = _FailInjectingRtcFactory();
      final pair = _Pair(factoryA: recording);
      addTearDown(pair.close);
      await pair.start();

      final linkA = await _stage(
        'connect',
        pair.transportA.connect(pair.peerB),
      );
      await pair.remoteLink();
      expect(recording.created, isNotEmpty);

      await _stage('forceFailure', recording.created.first.close());
      await _stage(
        'reconnected',
        _waitUntil(
          () =>
              recording.created.length > 1 &&
              linkA.state == PeerLinkState.connected &&
              pair.transportB.linkFor(pair.peerA)?.state ==
                  PeerLinkState.connected,
          timeout: const Duration(seconds: 30),
          reason: 'new PeerConnection after failure',
        ),
      );

      final linkB = pair.transportB.linkFor(pair.peerA)!;
      final controlFromB = linkB.incoming
          .firstWhere((incoming) => incoming.channel == PeerChannels.control)
          .timeout(const Duration(seconds: 30));
      await _stage(
        'sendAfterReconnect',
        pair.transportA.send(pair.peerB, const <int>[31]),
      );
      expect((await _stage('recvControlB', controlFromB)).bytes, const <int>[
        31,
      ]);

      final fromA = linkA.incoming
          .firstWhere((incoming) => incoming.channel == PeerChannels.sync)
          .timeout(const Duration(seconds: 30));
      await _stage('sendSyncB', linkB.send(PeerChannels.sync, const <int>[32]));
      expect((await _stage('recvSyncA', fromA)).bytes, const <int>[32]);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _Pair {
  _Pair({RtcPeerFactory? factoryA, RtcPeerFactory? factoryB})
    : factoryA = factoryA ?? const FlutterRtcPeerFactory(),
      factoryB = factoryB ?? const FlutterRtcPeerFactory() {
    channelA = bus.create(peerA);
    channelB = bus.create(peerB);
    transportA = WebRtcTransport(
      localPeerId: peerA,
      signaling: channelA,
      topic: topic,
      config: _nativeConfig,
      factory: this.factoryA,
    );
    transportB = WebRtcTransport(
      localPeerId: peerB,
      signaling: channelB,
      topic: topic,
      config: _nativeConfig,
      factory: this.factoryB,
    );
  }

  final String topic = 'room:native';
  final PeerId peerA = _peerId(1);
  final PeerId peerB = _peerId(2);
  final _SignalingBus bus = _SignalingBus();
  final RtcPeerFactory factoryA;
  final RtcPeerFactory factoryB;
  late final _SignalingChannel channelA;
  late final _SignalingChannel channelB;
  late final WebRtcTransport transportA;
  late final WebRtcTransport transportB;

  Future<void> start() async {
    await _stage('startA', transportA.start());
    await _stage('startB', transportB.start());
  }

  Future<PeerLink> remoteLink() async {
    await _stage(
      'remoteLink',
      _waitUntil(
        () => transportB.linkFor(peerA)?.state == PeerLinkState.connected,
        timeout: const Duration(seconds: 20),
        reason: 'passive real link connected',
      ),
    );
    return transportB.linkFor(peerA)!;
  }

  Future<void> close() async {
    await transportA.close();
    await transportB.close();
  }
}

class _FailInjectingRtcFactory implements RtcPeerFactory {
  final RtcPeerFactory _inner = const FlutterRtcPeerFactory();
  final List<_FailInjectingConnection> created = <_FailInjectingConnection>[];

  @override
  Future<RtcPeerConnection> create(Map<String, dynamic> configuration) async {
    final connection = _FailInjectingConnection(
      await _inner.create(configuration),
    );
    created.add(connection);
    return connection;
  }

  Future<void> failLatest() => created.last.fail();
}

/// Обёртка, позволяющая эмулировать failure на уровне RtcPeerConnection,
/// не дожидаясь ICE-таймаута.
class _FailInjectingConnection implements RtcPeerConnection {
  _FailInjectingConnection(this._inner) {
    _subscription = _inner.connectionStates.listen((state) {
      if (!_states.isClosed) {
        _states.add(state);
      }
    });
  }

  final RtcPeerConnection _inner;
  final StreamController<RtcConnectionState> _states =
      StreamController<RtcConnectionState>.broadcast();
  late final StreamSubscription<RtcConnectionState> _subscription;
  bool _failed = false;

  Future<void> fail() async {
    if (_failed) {
      return;
    }
    _failed = true;
    if (!_states.isClosed) {
      _states.add(RtcConnectionState.failed);
    }
    await _inner.close();
  }

  @override
  RtcSignalingState get signalingState => _inner.signalingState;

  @override
  RtcConnectionState get connectionState => _inner.connectionState;

  @override
  Stream<RtcIceCandidateData> get iceCandidates => _inner.iceCandidates;

  @override
  Stream<RtcConnectionState> get connectionStates => _states.stream;

  @override
  Stream<RtcDataChannel> get dataChannels => _inner.dataChannels;

  @override
  Stream<void> get negotiationNeeded => _inner.negotiationNeeded;

  @override
  Future<RtcSessionDescriptionData> createOffer({bool iceRestart = false}) =>
      _inner.createOffer(iceRestart: iceRestart);

  @override
  Future<RtcSessionDescriptionData> createAnswer() => _inner.createAnswer();

  @override
  Future<void> setLocalDescription(RtcSessionDescriptionData description) =>
      _inner.setLocalDescription(description);

  @override
  Future<void> setRemoteDescription(RtcSessionDescriptionData description) =>
      _inner.setRemoteDescription(description);

  @override
  Future<void> addIceCandidate(RtcIceCandidateData candidate) =>
      _inner.addIceCandidate(candidate);

  @override
  Future<void> restartIce() => _inner.restartIce();

  @override
  Future<List<RtcStats>> getStats() => _inner.getStats();

  @override
  Future<RtcDataChannel> createDataChannel(
    String label, {
    required bool ordered,
    int? maxRetransmits,
  }) => _inner.createDataChannel(
    label,
    ordered: ordered,
    maxRetransmits: maxRetransmits,
  );

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _inner.close();
    if (!_states.isClosed) {
      await _states.close();
    }
  }
}

const _nativeConfig = PeerConnectionConfig(
  iceServers: <IceServerConfig>[],
  connectTimeout: Duration(seconds: 20),
  iceRestartTimeout: Duration(seconds: 15),
  disconnectedGrace: Duration(seconds: 2),
  statsInterval: Duration(milliseconds: 500),
  maxReconnectAttempts: 3,
  reconnectBaseDelay: Duration(milliseconds: 300),
  reconnectMaxDelay: Duration(seconds: 2),
);

Future<void> _expectRoundTrip(
  String channel,
  PeerLink linkA,
  PeerLink linkB,
  Transport transportA,
  Transport transportB,
  PeerId peerA,
  PeerId peerB,
  List<int> fromA,
  List<int> fromB,
) async {
  await _expectDirection(channel, linkA, linkB, transportA, peerB, fromA);
  await _expectDirection(channel, linkB, linkA, transportB, peerA, fromB);
}

Future<void> _expectDirection(
  String channel,
  PeerLink senderLink,
  PeerLink receiverLink,
  Transport senderTransport,
  PeerId destination,
  List<int> bytes,
) async {
  final incoming = receiverLink.incoming
      .firstWhere((message) => message.channel == channel)
      .timeout(const Duration(seconds: 30));
  if (channel == PeerChannels.control && senderTransport is WebRtcTransport) {
    await _stage('send-$channel', senderTransport.send(destination, bytes));
  } else {
    await _stage('send-$channel', senderLink.send(channel, bytes));
  }
  final received = await _stage('recv-$channel', incoming);
  expect(received.bytes, bytes);
}

Future<T> _stage<T>(String name, Future<T> operation) {
  return operation.timeout(
    const Duration(seconds: 30),
    onTimeout: () => throw StateError('stage timeout: $name'),
  );
}

Future<void> _waitUntil(
  bool Function() predicate, {
  required Duration timeout,
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('waitUntil timeout: $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

PeerId _peerId(int seed) => PeerId(
  Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xFF)),
);

class _SignalingBus {
  final List<_SignalingChannel> _channels = <_SignalingChannel>[];

  _SignalingChannel create(PeerId peerId) {
    final channel = _SignalingChannel(peerId, this);
    _channels.add(channel);
    return channel;
  }

  void route(SignalingPacket packet) {
    for (final channel in List<_SignalingChannel>.of(_channels)) {
      if (channel.peerId == packet.from || channel.isClosed) {
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

class _SignalingChannel implements RichSignalingChannel {
  _SignalingChannel(this.peerId, this._bus);

  final PeerId peerId;
  final _SignalingBus _bus;
  final Set<String> joinedTopics = <String>{};
  final StreamController<SignalingPacket> _packets =
      StreamController<SignalingPacket>.broadcast();
  final StreamController<PeerPresence> _presence =
      StreamController<PeerPresence>.broadcast();
  bool isClosed = false;

  @override
  Stream<SignalingMessage> get incoming => _packets.stream.map(
    (packet) => SignalingMessage(
      topic: packet.topic,
      bytes: packet.bytes,
      from: packet.from,
      timestamp: packet.timestamp,
    ),
  );

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
      throw StateError('signaling channel is closed');
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
