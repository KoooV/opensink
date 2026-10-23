@TestOn('browser')
library;

import 'dart:convert';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_signaling/core_signaling.dart';
import 'package:test/test.dart';

import 'support/fake_ws_relays.dart';
import 'support/test_helpers.dart';

/// Web-путь: те же Nostr/Tracker каналы через `package:web_socket`.
/// Fake-реле реализованы на `fakes()` и не используют dart:io.
void main() {
  group('signaling web transport', () {
    late FakeNostrBusRelay nostr;
    late FakeTrackerBusRelay tracker;
    late GroupSecret groupSecret;
    late TestPeer alice;
    late TestPeer bob;
    late NostrSignaling aliceNostr;
    late NostrSignaling bobNostr;
    late TrackerSignaling aliceTracker;
    late TrackerSignaling bobTracker;
    late String topic;

    setUp(() async {
      nostr = FakeNostrBusRelay();
      tracker = FakeTrackerBusRelay();
      groupSecret = await GroupSecret.random();
      topic = await groupSecret.topicHex();
      alice = await TestPeer.create();
      bob = await TestPeer.create();
      aliceNostr = _nostr(alice, groupSecret, nostr);
      bobNostr = _nostr(bob, groupSecret, nostr);
      aliceTracker = _tracker(alice, groupSecret, tracker);
      bobTracker = _tracker(bob, groupSecret, tracker);
      await aliceNostr.join(topic);
      await bobNostr.join(topic);
      await aliceTracker.join(topic);
      await bobTracker.join(topic);
      await waitFor(
        () =>
            aliceNostr.connectedRelayCount == 1 &&
            bobNostr.connectedRelayCount == 1 &&
            aliceTracker.connectedRelayCount == 1 &&
            bobTracker.connectedRelayCount == 1,
        timeout: const Duration(seconds: 10),
      );
      await waitFor(
        () => tracker.peerCount >= 2,
        timeout: const Duration(seconds: 10),
      );
    });

    tearDown(() async {
      await aliceNostr.close();
      await bobNostr.close();
      await aliceTracker.close();
      await bobTracker.close();
      await nostr.stop();
      await tracker.stop();
    });

    test('exchanges presence and SDP over browser sockets', () async {
      final presence = bobNostr.presence.firstWhere(
        (value) => value.peerId == alice.peerId,
      );
      await aliceNostr.publishTo(
        topic,
        kind: SignalingKind.hello,
        bytes: SecureSignalingCodec.encodeHello(alice.capabilities()),
      );
      expect(
        (await presence.timeout(const Duration(seconds: 5))).peerId,
        alice.peerId,
      );

      final offer = bobTracker.incoming.first.timeout(
        const Duration(seconds: 5),
      );
      await aliceTracker.publish(topic, utf8.encode('web-offer'));
      expect(utf8.decode((await offer).bytes), 'web-offer');

      final answer = aliceTracker.incoming.first.timeout(
        const Duration(seconds: 5),
      );
      await bobTracker.publishTo(
        topic,
        kind: SignalingKind.answer,
        to: alice.peerId,
        bytes: utf8.encode('web-answer'),
      );
      expect(utf8.decode((await answer).bytes), 'web-answer');
    });
  });
}

NostrSignaling _nostr(
  TestPeer peer,
  GroupSecret groupSecret,
  WebSocketConnector connector,
) => NostrSignaling(
  security: peer.security(groupSecret),
  relays: NostrRelayConfig(
    invitationRelays: <Uri>[Uri.parse('ws://fake-nostr')],
    defaultRelays: const <Uri>[],
  ),
  connector: connector,
  helloInterval: const Duration(seconds: 5),
  presenceTtl: const Duration(seconds: 30),
  reconnectPolicy: const ReconnectPolicy(
    baseDelay: Duration(milliseconds: 50),
    maxDelay: Duration(milliseconds: 500),
    connectTimeout: Duration(seconds: 2),
  ),
);

TrackerSignaling _tracker(
  TestPeer peer,
  GroupSecret groupSecret,
  WebSocketConnector connector,
) => TrackerSignaling(
  security: peer.security(groupSecret),
  relays: TrackerRelayConfig(
    invitationRelays: <Uri>[Uri.parse('ws://fake-tracker')],
    defaultRelays: const <Uri>[],
  ),
  connector: connector,
  capabilities: peer.capabilities(),
  helloInterval: const Duration(seconds: 5),
  presenceTtl: const Duration(seconds: 30),
  offersPerAnnounce: 3,
  reconnectPolicy: const ReconnectPolicy(
    baseDelay: Duration(milliseconds: 50),
    maxDelay: Duration(milliseconds: 500),
    connectTimeout: Duration(seconds: 2),
  ),
);
