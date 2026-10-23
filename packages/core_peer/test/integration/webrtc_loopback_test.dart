import 'package:core_domain/core_domain.dart';
import 'package:core_peer/core_peer.dart';
import 'package:core_peer/core_peer_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_signaling.dart';
import '../support/test_helpers.dart';

/// Интеграционный тест реального WebRTC (flutter_webrtc).
///
/// Запуск:
///   flutter test --platform chrome --dart-define=PEER_REAL_WEBRTC=true \
///     test/integration/webrtc_loopback_test.dart
///   flutter test --dart-define=PEER_REAL_WEBRTC=true \
///     test/integration/webrtc_loopback_test.dart
///
/// Signaling — in-memory fake слоя 5; проверяется именно RTCPeerConnection,
/// DataChannel, ICE restart и закрытие.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const enabled = bool.fromEnvironment('PEER_REAL_WEBRTC');
  test(
    'real WebRTC: connect, exchange, survive network change, close',
    skip: enabled ? false : 'set --dart-define=PEER_REAL_WEBRTC=true',
    () async {
      const config = PeerConnectionConfig(
        iceServers: <IceServerConfig>[],
        connectTimeout: Duration(seconds: 15),
        iceRestartTimeout: Duration(seconds: 10),
        disconnectedGrace: Duration(seconds: 2),
        statsInterval: Duration(milliseconds: 500),
        maxReconnectAttempts: 3,
        reconnectBaseDelay: Duration(milliseconds: 300),
        reconnectMaxDelay: Duration(seconds: 2),
      );
      const factory = FlutterRtcPeerFactory();
      final bus = FakeSignalingBus();
      final peerA = peerId(1);
      final peerB = peerId(2);
      final channelA = bus.create(peerA);
      final channelB = bus.create(peerB);
      final transportA = WebRtcTransport(
        localPeerId: peerA,
        signaling: channelA,
        topic: 'room:webrtc',
        config: config,
        factory: factory,
      );
      final transportB = WebRtcTransport(
        localPeerId: peerB,
        signaling: channelB,
        topic: 'room:webrtc',
        config: config,
        factory: factory,
      );
      addTearDown(() async {
        await transportA.close();
        await transportB.close();
      });

      await _stage('startA', transportA.start());
      await _stage('startB', transportB.start());
      final linkA = await _stage('connect', transportA.connect(peerB));
      expect(linkA.state, PeerLinkState.connected);

      await _stage(
        'remoteLink',
        waitUntil(
          () => transportB.linkFor(peerA)?.state == PeerLinkState.connected,
          timeout: const Duration(seconds: 20),
          reason: 'passive real link connected',
        ),
      );
      final linkB = transportB.linkFor(peerA)!;

      final fromB = linkB.incoming
          .firstWhere((incoming) => incoming.channel == PeerChannels.control)
          .timeout(const Duration(seconds: 10));
      await _stage('sendA', transportA.send(peerB, const <int>[1, 2, 3, 4]));
      expect((await _stage('recvB', fromB)).bytes, const <int>[1, 2, 3, 4]);

      final fromA = linkA.incoming
          .firstWhere((incoming) => incoming.channel == PeerChannels.control)
          .timeout(const Duration(seconds: 10));
      await _stage('sendB', transportB.send(peerA, const <int>[5, 6]));
      expect((await _stage('recvA', fromA)).bytes, const <int>[5, 6]);

      transportA.notifyNetworkChanged();
      await _stage(
        'afterRestart',
        waitUntil(
          () => linkA.state == PeerLinkState.connected,
          timeout: const Duration(seconds: 20),
          reason: 'real link reconnected after ICE restart',
        ),
      );
      final afterRestart = linkB.incoming
          .firstWhere((incoming) => incoming.channel == PeerChannels.control)
          .timeout(const Duration(seconds: 10));
      await _stage('sendAfterRestart', transportA.send(peerB, const <int>[7]));
      expect(
        (await _stage('recvAfterRestart', afterRestart)).bytes,
        const <int>[7],
      );

      final closedOnB = linkB.stateStream
          .firstWhere((state) => state == PeerLinkState.closed)
          .timeout(const Duration(seconds: 10));
      await _stage('closeA', transportA.close());
      await _stage('closedOnB', closedOnB);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

Future<T> _stage<T>(String name, Future<T> operation) {
  return operation.timeout(
    const Duration(seconds: 25),
    onTimeout: () => throw StateError('stage timeout: $name'),
  );
}
