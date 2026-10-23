@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_signaling/core_signaling.dart';
import 'package:test/test.dart';

import 'support/fake_nostr_relay.dart';
import 'support/fake_tracker_relay.dart';
import 'support/test_helpers.dart';

void main() {
  test('publishes through both backends and deduplicates incoming', () async {
    final nostrRelays = <FakeNostrRelay>[
      await FakeNostrRelay.start(),
      await FakeNostrRelay.start(),
      await FakeNostrRelay.start(),
    ];
    final trackerRelays = <FakeTrackerRelay>[
      await FakeTrackerRelay.start(),
      await FakeTrackerRelay.start(),
      await FakeTrackerRelay.start(),
    ];
    final groupSecret = await GroupSecret.random();
    final topic = await groupSecret.topicHex();
    final alice = await TestPeer.create();
    final bob = await TestPeer.create();

    final aliceNostr = _nostr(alice, groupSecret, nostrRelays);
    final aliceTracker = _tracker(alice, groupSecret, trackerRelays);
    final bobNostr = _nostr(bob, groupSecret, nostrRelays);
    final bobTracker = _tracker(bob, groupSecret, trackerRelays);
    final alicePool = SignalingChannelPool(
      channels: <RichSignalingChannel>[aliceNostr, aliceTracker],
    );
    final bobPool = SignalingChannelPool(
      channels: <RichSignalingChannel>[bobNostr, bobTracker],
    );

    try {
      await alicePool.join(topic);
      await bobPool.join(topic);
      await waitFor(
        () =>
            aliceNostr.connectedRelayCount == 3 &&
            aliceTracker.connectedRelayCount == 3 &&
            bobNostr.connectedRelayCount == 3 &&
            bobTracker.connectedRelayCount == 3,
        timeout: const Duration(seconds: 10),
      );
      await waitFor(
        () => trackerRelays.every((relay) => relay.peerCount >= 2),
        timeout: const Duration(seconds: 10),
      );

      final collected = collectFor(
        bobPool.packets,
        const Duration(milliseconds: 600),
      );
      await alicePool.publish(topic, utf8.encode('both-backends'));
      final packets = await collected;
      expect(packets, hasLength(1));
      expect(utf8.decode(packets.single.bytes), 'both-backends');
      expect(packets.single.from, alice.peerId);
    } finally {
      await alicePool.close();
      await bobPool.close();
      for (final relay in nostrRelays) {
        await relay.stop();
      }
      for (final relay in trackerRelays) {
        await relay.stop();
      }
    }
  });

  test('survives one failed relay in each backend', () async {
    final nostrRelays = <FakeNostrRelay>[
      await FakeNostrRelay.start(),
      await FakeNostrRelay.start(),
      await FakeNostrRelay.start(),
    ];
    final trackerRelays = <FakeTrackerRelay>[
      await FakeTrackerRelay.start(),
      await FakeTrackerRelay.start(),
      await FakeTrackerRelay.start(),
    ];
    final groupSecret = await GroupSecret.random();
    final topic = await groupSecret.topicHex();
    final alice = await TestPeer.create();
    final bob = await TestPeer.create();

    final aliceNostr = _nostr(alice, groupSecret, nostrRelays);
    final aliceTracker = _tracker(alice, groupSecret, trackerRelays);
    final bobNostr = _nostr(bob, groupSecret, nostrRelays);
    final bobTracker = _tracker(bob, groupSecret, trackerRelays);
    final alicePool = SignalingChannelPool(
      channels: <RichSignalingChannel>[aliceNostr, aliceTracker],
    );
    final bobPool = SignalingChannelPool(
      channels: <RichSignalingChannel>[bobNostr, bobTracker],
    );

    try {
      await alicePool.join(topic);
      await bobPool.join(topic);
      await waitFor(
        () =>
            aliceNostr.connectedRelayCount == 3 &&
            aliceTracker.connectedRelayCount == 3 &&
            bobNostr.connectedRelayCount == 3 &&
            bobTracker.connectedRelayCount == 3,
        timeout: const Duration(seconds: 10),
      );
      await waitFor(
        () => trackerRelays.every((relay) => relay.peerCount >= 2),
        timeout: const Duration(seconds: 10),
      );

      await nostrRelays.first.stop();
      await trackerRelays.first.stop();
      await waitFor(
        () =>
            aliceNostr.connectedRelayCount == 2 &&
            aliceTracker.connectedRelayCount == 2 &&
            bobNostr.connectedRelayCount == 2 &&
            bobTracker.connectedRelayCount == 2,
        timeout: const Duration(seconds: 10),
        reason: 'each backend must fail over to its remaining relays',
      );

      final presence = bobPool.presence.firstWhere(
        (value) => value.peerId == alice.peerId,
      );
      await alicePool.publishTo(
        topic,
        kind: SignalingKind.hello,
        bytes: SecureSignalingCodec.encodeHello(alice.capabilities()),
      );
      expect(
        (await presence.timeout(const Duration(seconds: 5))).peerId,
        alice.peerId,
      );

      final packet = bobPool.packets.firstWhere(
        (value) => utf8.decode(value.bytes) == 'after-one-relay-each',
      );
      await alicePool.publish(topic, utf8.encode('after-one-relay-each'));
      final received = await packet.timeout(const Duration(seconds: 5));
      expect(received.from, alice.peerId);
    } finally {
      await alicePool.close();
      await bobPool.close();
      for (final relay in nostrRelays) {
        await relay.stop();
      }
      for (final relay in trackerRelays) {
        await relay.stop();
      }
    }
  });

  test('isolates a failing backend channel', () async {
    final failing = _ScriptedChannel()..failOperations = true;
    final healthy = _ScriptedChannel();
    final pool = SignalingChannelPool(
      channels: <RichSignalingChannel>[failing, healthy],
    );

    try {
      await pool.join('topic');
      await pool.publishTo(
        'topic',
        kind: SignalingKind.data,
        bytes: <int>[1, 2],
      );
      expect(healthy.published, <List<int>>[
        <int>[1, 2],
      ]);
    } finally {
      await pool.close();
    }
    expect(healthy.closed, isTrue);
  });

  test('deduplicates by recipient as well as payload', () async {
    final alice = PeerId(Uint8List.fromList(List<int>.filled(32, 1)));
    final bob = PeerId(Uint8List.fromList(List<int>.filled(32, 2)));
    final carol = PeerId(Uint8List.fromList(List<int>.filled(32, 3)));
    final first = _ScriptedChannel();
    final second = _ScriptedChannel();
    final pool = SignalingChannelPool(
      channels: <RichSignalingChannel>[first, second],
    );
    final received = <SignalingPacket>[];
    final subscription = pool.packets.listen(received.add);

    try {
      final toBob = SignalingPacket(
        topic: 'topic',
        kind: SignalingKind.answer,
        from: alice,
        to: bob,
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        timestamp: 1,
      );
      first.emit(toBob);
      second.emit(toBob);
      first.emit(
        SignalingPacket(
          topic: 'topic',
          kind: SignalingKind.answer,
          from: alice,
          to: carol,
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          timestamp: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(2));
      expect(received.map((packet) => packet.to), <PeerId?>[bob, carol]);
    } finally {
      await subscription.cancel();
      await pool.close();
    }
  });
}

class _ScriptedChannel implements RichSignalingChannel {
  final StreamController<SignalingPacket> _packets =
      StreamController<SignalingPacket>.broadcast();
  final StreamController<PeerPresence> _presence =
      StreamController<PeerPresence>.broadcast();

  final List<List<int>> published = <List<int>>[];
  bool failOperations = false;
  bool closed = false;

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
    if (failOperations) {
      throw StateError('join failed');
    }
  }

  @override
  Future<void> publish(String topic, List<int> bytes) async {
    if (failOperations) {
      throw StateError('publish failed');
    }
  }

  @override
  Future<void> publishTo(
    String topic, {
    required SignalingKind kind,
    PeerId? to,
    required List<int> bytes,
  }) async {
    if (failOperations) {
      throw StateError('publishTo failed');
    }
    published.add(bytes);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _packets.close();
    await _presence.close();
    if (failOperations) {
      throw StateError('close failed');
    }
  }

  void emit(SignalingPacket packet) => _packets.add(packet);
}

NostrSignaling _nostr(
  TestPeer peer,
  GroupSecret groupSecret,
  List<FakeNostrRelay> relays,
) => NostrSignaling(
  security: peer.security(groupSecret),
  relays: NostrRelayConfig(
    invitationRelays: relays.map((relay) => relay.uri),
    defaultRelays: const <Uri>[],
  ),
  helloInterval: const Duration(seconds: 5),
  reconnectPolicy: const ReconnectPolicy(
    baseDelay: Duration(milliseconds: 50),
    maxDelay: Duration(milliseconds: 500),
    connectTimeout: Duration(seconds: 2),
  ),
);

TrackerSignaling _tracker(
  TestPeer peer,
  GroupSecret groupSecret,
  List<FakeTrackerRelay> relays,
) => TrackerSignaling(
  security: peer.security(groupSecret),
  relays: TrackerRelayConfig(
    invitationRelays: relays.map((relay) => relay.uri),
    defaultRelays: const <Uri>[],
  ),
  helloInterval: const Duration(seconds: 5),
  reconnectPolicy: const ReconnectPolicy(
    baseDelay: Duration(milliseconds: 50),
    maxDelay: Duration(milliseconds: 500),
    connectTimeout: Duration(seconds: 2),
  ),
);
