import 'package:core_domain/core_domain.dart';
import 'package:core_peer/core_peer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_rtc.dart';
import 'support/fake_signaling.dart';
import 'support/test_helpers.dart';

const _testConfig = PeerConnectionConfig(
  connectTimeout: Duration(seconds: 3),
  iceRestartTimeout: Duration(seconds: 2),
  disconnectedGrace: Duration(milliseconds: 50),
  statsInterval: Duration(milliseconds: 20),
  maxConcurrentLinks: 4,
  maxReconnectAttempts: 3,
  reconnectBaseDelay: Duration(milliseconds: 10),
  reconnectMaxDelay: Duration(milliseconds: 40),
  bufferedAmountHighWater: 100,
  bufferedAmountLowThreshold: 20,
);

const _shortTimeoutConfig = PeerConnectionConfig(
  connectTimeout: Duration(milliseconds: 400),
  maxConcurrentLinks: 4,
  maxReconnectAttempts: 2,
  reconnectBaseDelay: Duration(milliseconds: 10),
  reconnectMaxDelay: Duration(milliseconds: 40),
);

const _singleLinkConfig = PeerConnectionConfig(
  connectTimeout: Duration(seconds: 3),
  statsInterval: Duration(milliseconds: 20),
  maxConcurrentLinks: 1,
  maxReconnectAttempts: 2,
  reconnectBaseDelay: Duration(milliseconds: 10),
  reconnectMaxDelay: Duration(milliseconds: 40),
);

const _terminalFailureConfig = PeerConnectionConfig(
  connectTimeout: Duration(seconds: 3),
  statsInterval: Duration(milliseconds: 20),
  maxConcurrentLinks: 1,
  maxReconnectAttempts: 0,
  reconnectBaseDelay: Duration(milliseconds: 10),
  reconnectMaxDelay: Duration(milliseconds: 40),
);

class _Fixture {
  _Fixture({
    PeerConnectionConfig config = _testConfig,
    FakeRtcBehavior behavior = const FakeRtcBehavior(packetLoss: 0.1),
    PeerPriorityPolicy priorityPolicy = const DefaultPeerPriorityPolicy(),
  }) : factory = FakeRtcPeerFactory(behavior: behavior) {
    bus = FakeSignalingBus();
    channelA = bus.create(peerA);
    channelB = bus.create(peerB);
    transportA = WebRtcTransport(
      localPeerId: peerA,
      signaling: channelA,
      topic: topic,
      config: config,
      factory: factory,
      priorityPolicy: priorityPolicy,
    );
    transportB = WebRtcTransport(
      localPeerId: peerB,
      signaling: channelB,
      topic: topic,
      config: config,
      factory: factory,
      priorityPolicy: priorityPolicy,
    );
  }

  final PeerId peerA = peerId(1);
  final PeerId peerB = peerId(2);
  final String topic = 'room:test';
  final FakeRtcPeerFactory factory;
  late final FakeSignalingBus bus;
  late final FakeRichSignalingChannel channelA;
  late final FakeRichSignalingChannel channelB;
  late final WebRtcTransport transportA;
  late final WebRtcTransport transportB;

  Future<void> start() async {
    await transportA.start();
    await transportB.start();
  }

  Future<void> close() async {
    await transportA.close();
    await transportB.close();
  }

  FakeRtcPeerConnection connectionOf(WebRtcTransport transport) {
    return factory.network.connections.firstWhere(
      (connection) =>
          connection.connectionState != RtcConnectionState.closed &&
          connection.channel(PeerChannels.control) != null,
      orElse: () => factory.network.connections.last,
    );
  }
}

void main() {
  group('WebRtcTransport (fake RTC + fake signaling layer 5)', () {
    test('two peers connect, exchange control messages and close', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.start();

      final linkA = await fixture.transportA.connect(fixture.peerB);
      expect(linkA.state, PeerLinkState.connected);

      await waitUntil(
        () =>
            fixture.transportB.linkFor(fixture.peerA)?.state ==
            PeerLinkState.connected,
        reason: 'passive link connected',
      );
      final linkB = fixture.transportB.linkFor(fixture.peerA)!;

      final fromA = linkB.incoming
          .firstWhere((incoming) => incoming.channel == PeerChannels.control)
          .timeout(const Duration(seconds: 2));
      await fixture.transportA.send(fixture.peerB, const <int>[1, 2, 3]);
      final receivedA = await fromA;
      expect(receivedA.bytes, const <int>[1, 2, 3]);
      expect(receivedA.channel, PeerChannels.control);

      final fromB = linkA.incoming
          .firstWhere((incoming) => incoming.channel == PeerChannels.control)
          .timeout(const Duration(seconds: 2));
      await fixture.transportB.send(fixture.peerA, const <int>[9, 8]);
      expect((await fromB).bytes, const <int>[9, 8]);

      final closed = linkB.stateStream
          .firstWhere((state) => state == PeerLinkState.closed)
          .timeout(const Duration(seconds: 2));
      await fixture.transportA.close();
      await closed;
      await waitUntil(
        () => fixture.transportB.linkFor(fixture.peerA) == null,
        reason: 'hangup removes link on remote',
      );
    });

    test('statsFor отдаёт статистику прямого линка', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.start();
      await fixture.transportA.connect(fixture.peerB);

      final link = fixture.transportA.linkFor(fixture.peerB)!;

      expect(fixture.transportA.statsFor(fixture.peerB), link.stats);
      expect(fixture.transportA.statsFor(peerId(3)), isNull);
    });

    test('presence neighbors следуют за direct-линками', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.start();

      await fixture.transportA.connect(fixture.peerB);
      await waitUntil(
        () =>
            fixture.channelA.neighborUpdates.isNotEmpty &&
            fixture.channelA.neighborUpdates.last.contains(fixture.peerB),
        reason: 'A must announce its direct link to B',
      );
      await waitUntil(
        () =>
            fixture.channelB.neighborUpdates.isNotEmpty &&
            fixture.channelB.neighborUpdates.last.contains(fixture.peerA),
        reason: 'B must announce its direct link to A',
      );

      await fixture.transportA.close();

      await waitUntil(
        () => fixture.channelA.neighborUpdates.last.isEmpty,
        reason: 'A must clear neighbors on close',
      );
      await waitUntil(
        () =>
            fixture.channelB.neighborUpdates.isNotEmpty &&
            fixture.channelB.neighborUpdates.last.isEmpty,
        reason: 'B must clear neighbors after disconnect',
      );
    });

    test('relay channel is separate from control', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.start();

      await fixture.transportA.connect(fixture.peerB);
      await waitUntil(
        () =>
            fixture.transportB.linkFor(fixture.peerA)?.state ==
            PeerLinkState.connected,
        reason: 'passive link connected',
      );

      final incoming = fixture.transportB.relayIncoming
          .firstWhere((datagram) => datagram.from == fixture.peerA)
          .timeout(const Duration(seconds: 2));
      await fixture.transportA.sendRelay(
        fixture.peerB,
        const <int>[7, 7, 7],
      );
      final received = await incoming;
      expect(received.bytes, const <int>[7, 7, 7]);
    });

    test('does not busy-loop when signaling state is not stable', () async {
      final fixture = _Fixture(
        config: _shortTimeoutConfig,
        behavior: const FakeRtcBehavior(
          initialSignalingState: RtcSignalingState.haveRemoteOffer,
        ),
      );
      addTearDown(fixture.close);
      await fixture.start();

      await expectLater(
        fixture.transportA.connect(fixture.peerB),
        throwsA(isA<PeerConnectTimeout>()),
      );
    });

    test('perfect negotiation survives simultaneous connect (glare)', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.start();

      final links = await Future.wait<PeerLink>([
        fixture.transportA.connect(fixture.peerB),
        fixture.transportB.connect(fixture.peerA),
      ]).timeout(const Duration(seconds: 5));
      expect(links[0].state, PeerLinkState.connected);
      expect(links[1].state, PeerLinkState.connected);

      final fromB = links[1].incoming
          .firstWhere((incoming) => incoming.channel == PeerChannels.sync)
          .timeout(const Duration(seconds: 2));
      await links[0].send(PeerChannels.sync, const <int>[4, 5]);
      expect((await fromB).bytes, const <int>[4, 5]);

      final fromA = links[0].incoming
          .firstWhere((incoming) => incoming.channel == PeerChannels.sync)
          .timeout(const Duration(seconds: 2));
      await links[1].send(PeerChannels.sync, const <int>[6]);
      expect((await fromA).bytes, const <int>[6]);
    });

    test('file channel applies backpressure via bufferedAmount', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.start();
      final linkA = await fixture.transportA.connect(fixture.peerB);
      final linkB = await _waitForRemoteLink(fixture.transportB, fixture.peerA);

      final received = <List<int>>[];
      final subscription = linkB.incoming
          .where((incoming) => incoming.channel == PeerChannels.file)
          .listen((incoming) => received.add(incoming.bytes));
      addTearDown(subscription.cancel);

      final fileChannels = fixture.factory.network.connections
          .expand((connection) => connection.allChannels)
          .where((channel) => channel.label == PeerChannels.file)
          .toList();
      expect(fileChannels, isNotEmpty);
      for (final channel in fileChannels) {
        channel.autoDrain = false;
      }

      await linkA.send(PeerChannels.file, List<int>.filled(80, 1));
      await linkA.send(PeerChannels.file, List<int>.filled(80, 2));
      var completed = false;
      final blocked = linkA
          .send(PeerChannels.file, List<int>.filled(80, 3))
          .whenComplete(() => completed = true);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        completed,
        isFalse,
        reason: 'send must wait while bufferedAmount is above high water',
      );
      final buffered = fileChannels.fold<int>(
        0,
        (sum, channel) => sum + channel.bufferedAmount,
      );
      expect(buffered, greaterThan(_testConfig.bufferedAmountHighWater));

      for (final channel in fileChannels) {
        channel.autoDrain = true;
        channel.drain();
      }
      await blocked.timeout(const Duration(seconds: 2));
      await waitUntil(
        () => received.length == 3,
        reason: 'all file messages delivered after drain',
      );
      expect(received[2], List<int>.filled(80, 3));
    });

    test('stats exposes RTT, loss and outgoing bitrate', () async {
      final fixture = _Fixture(
        behavior: const FakeRtcBehavior(packetLoss: 0.1),
      );
      addTearDown(fixture.close);
      await fixture.start();
      final linkA = await fixture.transportA.connect(fixture.peerB);

      await fixture.transportA.send(fixture.peerB, List<int>.filled(64, 7));
      await waitUntil(
        () => linkA.stats.bytesSent >= 64,
        reason: 'bytesSent from getStats',
      );
      await fixture.transportA.send(fixture.peerB, List<int>.filled(64, 7));
      await waitUntil(
        () => linkA.stats.outgoingBitrate > 0,
        reason: 'outgoing bitrate after second sample',
      );
      expect(linkA.stats.rtt.inMilliseconds, inInclusiveRange(15, 25));
      expect(linkA.stats.loss, greaterThan(0.05));
      expect(linkA.stats.loss, lessThan(0.2));
    });

    test(
      'network change triggers ICE restart and keeps the link usable',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.close);
        await fixture.start();
        final linkA = await fixture.transportA.connect(fixture.peerB);
        await _waitForRemoteLink(fixture.transportB, fixture.peerA);
        final aConnection = fixture.connectionOf(fixture.transportA);

        fixture.transportA.notifyNetworkChanged();
        await waitUntil(
          () => aConnection.restartIceCount >= 1,
          reason: 'restartIce called',
        );
        await waitUntil(
          () => linkA.state == PeerLinkState.connected,
          reason: 'link reconnected after ICE restart',
        );

        final fromA = linkA.incoming
            .firstWhere((incoming) => incoming.channel == PeerChannels.control)
            .timeout(const Duration(seconds: 2));
        await fixture.transportB.send(fixture.peerA, const <int>[11]);
        expect((await fromA).bytes, const <int>[11]);
      },
    );

    test(
      'failed connection reconnects with backoff and restores traffic',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.close);
        await fixture.start();
        final linkA = await fixture.transportA.connect(fixture.peerB);
        await _waitForRemoteLink(fixture.transportB, fixture.peerA);
        final initialConnections = fixture.factory.network.connections.length;
        final oldConnection = fixture.connectionOf(fixture.transportA);

        oldConnection.simulateFailure();
        await waitUntil(
          () =>
              fixture.factory.network.connections.length > initialConnections &&
              linkA.state == PeerLinkState.connected,
          timeout: const Duration(seconds: 5),
          reason: 'new PeerConnection after failure',
        );
        expect(oldConnection.closeCount, greaterThanOrEqualTo(1));

        final fromB = linkA.incoming
            .firstWhere((incoming) => incoming.channel == PeerChannels.sync)
            .timeout(const Duration(seconds: 2));
        final remoteLink = fixture.transportB.linkFor(fixture.peerA)!;
        await remoteLink.send(PeerChannels.sync, const <int>[42]);
        expect((await fromB).bytes, const <int>[42]);
      },
    );

    test('connection limit evicts lower-priority peer', () async {
      final priorities = <String, int>{
        fixturePeerKey(peerId(2)): 1,
        fixturePeerKey(peerId(3)): 10,
      };
      final fixture = _Fixture(
        config: _singleLinkConfig,
        behavior: const FakeRtcBehavior(),
        priorityPolicy: _MapPriorityPolicy(priorities),
      );
      addTearDown(fixture.close);
      final peerC = peerId(3);
      final channelC = fixture.bus.create(peerC);
      final transportC = WebRtcTransport(
        localPeerId: peerC,
        signaling: channelC,
        topic: fixture.topic,
        config: _singleLinkConfig,
        factory: fixture.factory,
        priorityPolicy: _MapPriorityPolicy(priorities),
      );
      addTearDown(transportC.close);

      await fixture.transportA.start();
      await fixture.transportB.start();
      await transportC.start();

      final low = await fixture.transportA.connect(fixture.peerB);
      expect(low.state, PeerLinkState.connected);

      final high = await fixture.transportA.connect(peerC);
      expect(high.state, PeerLinkState.connected);
      expect(fixture.transportA.linkFor(fixture.peerB), isNull);
      expect(fixture.transportA.linkFor(peerC), isNotNull);
      await waitUntil(
        () => low.state == PeerLinkState.closed,
        reason: 'low priority link evicted',
      );
    });

    test('presence channel is unreliable (maxRetransmits=0, unordered)', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.start();
      await fixture.transportA.connect(fixture.peerB);
      await _waitForRemoteLink(fixture.transportB, fixture.peerA);

      final presenceChannels = fixture.factory.network.connections
          .expand((connection) => connection.allChannels)
          .where((channel) => channel.label == PeerChannels.presence)
          .toList();
      expect(presenceChannels, isNotEmpty);
      for (final channel in presenceChannels) {
        expect(channel.ordered, isFalse);
        expect(channel.maxRetransmits, 0);
      }
    });

    test('failed link frees its slot; send to failed link rejects', () async {
      final fixture = _Fixture(config: _terminalFailureConfig);
      addTearDown(fixture.close);
      await fixture.start();

      final linkA = await fixture.transportA.connect(fixture.peerB);
      await _waitForRemoteLink(fixture.transportB, fixture.peerA);
      for (final connection in fixture.factory.network.connections) {
        if (connection.connectionState != RtcConnectionState.closed &&
            connection.channel(PeerChannels.control) != null) {
          connection.simulateFailure();
        }
      }
      await waitUntil(
        () =>
            linkA.state == PeerLinkState.failed ||
            linkA.state == PeerLinkState.closed,
        reason: 'link reached terminal state after exhausted reconnect attempts',
      );
      await waitUntil(
        () => fixture.transportA.linkFor(fixture.peerB) == null,
        reason: 'failed link removed from transport',
      );

      await expectLater(
        fixture.transportA.send(fixture.peerB, const <int>[1]),
        throwsStateError,
        reason: 'send to failed link rejects without auto-connect',
      );

      final peerC = peerId(3);
      final channelC = fixture.bus.create(peerC);
      final transportC = WebRtcTransport(
        localPeerId: peerC,
        signaling: channelC,
        topic: fixture.topic,
        config: _terminalFailureConfig,
        factory: fixture.factory,
        priorityPolicy: const DefaultPeerPriorityPolicy(),
      );
      addTearDown(transportC.close);
      await transportC.start();

      final linkC = await fixture.transportA.connect(peerC);
      expect(linkC.state, PeerLinkState.connected);
      expect(fixture.transportA.linkFor(peerC), isNotNull);
    });

    test('parallel connect to the same peer returns one link', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await fixture.start();

      final links = await Future.wait<PeerLink>([
        fixture.transportA.connect(fixture.peerB),
        fixture.transportA.connect(fixture.peerB),
      ]);
      expect(links.length, 2);
      expect(identical(links[0], links[1]), isTrue);
      expect(links[0].state, PeerLinkState.connected);
    });

    test('parallel connects respect maxConcurrentLinks', () async {
      final fixture = _Fixture(config: _singleLinkConfig);
      addTearDown(fixture.close);
      await fixture.start();

      final peerC = peerId(3);
      final outcomes = await Future.wait<String>([
        fixture
            .transportA
            .connect(fixture.peerB)
            .then((link) => 'ok:${link.remotePeerId}')
            .catchError((error) => 'fail:${error.runtimeType}'),
        fixture
            .transportA
            .connect(peerC)
            .then((link) => 'ok:${link.remotePeerId}')
            .catchError((error) => 'fail:${error.runtimeType}'),
      ]);
      expect(outcomes.where((o) => o.startsWith('ok:')), hasLength(1));
      expect(
        outcomes.any((o) => o.startsWith('fail:PeerCapacityExceeded')),
        isTrue,
      );
    });
  });
}

String fixturePeerKey(PeerId peer) => peer.publicKey.join(',');

class _MapPriorityPolicy implements PeerPriorityPolicy {
  _MapPriorityPolicy(this.priorities);

  final Map<String, int> priorities;

  @override
  int priorityOf(PeerId peerId) => priorities[fixturePeerKey(peerId)] ?? 0;

  @override
  bool isProtected(PeerId peerId) => false;
}

Future<PeerLink> _waitForRemoteLink(
  WebRtcTransport transport,
  PeerId peer,
) async {
  await waitUntil(
    () => transport.linkFor(peer)?.state == PeerLinkState.connected,
    reason: 'remote link connected',
  );
  return transport.linkFor(peer)!;
}
