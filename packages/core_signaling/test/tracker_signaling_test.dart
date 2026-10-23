@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_signaling/core_signaling.dart';
import 'package:test/test.dart';

import 'support/fake_tracker_relay.dart';
import 'support/test_helpers.dart';

void main() {
  group('TrackerSignaling', () {
    late List<FakeTrackerRelay> relays;
    late GroupSecret groupSecret;
    late TestPeer alice;
    late TestPeer bob;
    late TrackerSignaling aliceChannel;
    late TrackerSignaling bobChannel;
    late String topic;

    setUp(() async {
      relays = <FakeTrackerRelay>[
        await FakeTrackerRelay.start(),
        await FakeTrackerRelay.start(),
        await FakeTrackerRelay.start(),
      ];
      groupSecret = await GroupSecret.random();
      topic = await groupSecret.topicHex();
      alice = await TestPeer.create();
      bob = await TestPeer.create();
      aliceChannel = _channel(alice, groupSecret, relays);
      bobChannel = _channel(bob, groupSecret, relays);
      await aliceChannel.join(topic);
      await bobChannel.join(topic);
      await waitFor(
        () =>
            aliceChannel.connectedRelayCount == relays.length &&
            bobChannel.connectedRelayCount == relays.length,
        timeout: const Duration(seconds: 10),
        reason: 'both clients must connect to all trackers',
      );
      await waitFor(
        () => relays.every((relay) => relay.peerCount >= 2),
        timeout: const Duration(seconds: 10),
        reason: 'both clients must announce in every swarm',
      );
    });

    tearDown(() async {
      await aliceChannel.close();
      await bobChannel.close();
      for (final relay in relays) {
        await relay.stop();
      }
    });

    test('exchanges presence, offer and addressed answer', () async {
      final presence = bobChannel.presence.firstWhere(
        (value) => value.peerId == alice.peerId,
      );
      await aliceChannel.publishTo(
        topic,
        kind: SignalingKind.hello,
        bytes: SecureSignalingCodec.encodeHello(alice.capabilities()),
      );
      final seen = await presence.timeout(const Duration(seconds: 5));
      expect(seen.capabilities.platform, SignalingPlatform.linux);

      final offerFuture = bobChannel.incoming.first.timeout(
        const Duration(seconds: 5),
      );
      await aliceChannel.publish(topic, utf8.encode('tracker-offer-sdp'));
      final offer = await offerFuture;
      expect(offer.from, alice.peerId);
      expect(utf8.decode(offer.bytes), 'tracker-offer-sdp');

      final answerFuture = aliceChannel.incoming.first.timeout(
        const Duration(seconds: 5),
      );
      await bobChannel.publishTo(
        topic,
        kind: SignalingKind.answer,
        to: alice.peerId,
        bytes: utf8.encode('tracker-answer-sdp'),
      );
      final answer = await answerFuture;
      expect(answer.from, bob.peerId);
      expect(utf8.decode(answer.bytes), 'tracker-answer-sdp');
    });

    test('uses WebTorrent wire-compatible announce fields', () async {
      await waitFor(
        () => relays.first.announces.any(
          (announce) =>
              announce['offers'] is List &&
              (announce['offers'] as List).isNotEmpty,
        ),
        timeout: const Duration(seconds: 5),
        reason: 'hello must be sent as WebTorrent offers',
      );

      final withOffers = relays.first.announces.lastWhere((announce) {
        final offers = announce['offers'];
        return offers is List && offers.isNotEmpty;
      });
      expect((withOffers['info_hash'] as String).length, 20);
      expect((withOffers['peer_id'] as String).length, 20);
      final offers = withOffers['offers'] as List;
      expect(offers.length, inInclusiveRange(1, 5));
      for (final item in offers) {
        final offer = item as Map;
        expect((offer['offer_id'] as String).length, 20);
        final payload = offer['offer'] as Map;
        expect(payload['type'], 'offer');
        expect(payload['sdp'], startsWith(TrackerSignaling.sdpPrefix));
      }

      final answerFuture = aliceChannel.incoming.first.timeout(
        const Duration(seconds: 5),
      );
      await bobChannel.publishTo(
        topic,
        kind: SignalingKind.answer,
        to: alice.peerId,
        bytes: utf8.encode('wire-answer'),
      );
      await answerFuture;
      await waitFor(
        () => relays.first.announces.any(
          (announce) => announce['answer'] != null,
        ),
        timeout: const Duration(seconds: 5),
      );
      final answerAnnounce = relays.first.announces.lastWhere(
        (announce) => announce['answer'] != null,
      );
      expect((answerAnnounce['to_peer_id'] as String).length, 20);
      expect((answerAnnounce['offer_id'] as String).length, 20);
      final answer = answerAnnounce['answer'] as Map;
      expect(answer['type'], 'answer');
      expect(answer['sdp'], startsWith(TrackerSignaling.sdpPrefix));
    });

    test('deduplicates offers from several trackers', () async {
      final collected = collectFor(
        bobChannel.packets,
        const Duration(milliseconds: 500),
      );
      await aliceChannel.publish(topic, utf8.encode('dedup-tracker'));
      expect(await collected, hasLength(1));
    });

    test('survives one tracker failure', () async {
      await relays.first.stop();
      await waitFor(
        () =>
            aliceChannel.connectedRelayCount == 2 &&
            bobChannel.connectedRelayCount == 2,
        timeout: const Duration(seconds: 10),
      );
      final offerFuture = bobChannel.incoming.first.timeout(
        const Duration(seconds: 5),
      );
      await aliceChannel.publish(topic, utf8.encode('after-tracker-failure'));
      final offer = await offerFuture;
      expect(utf8.decode(offer.bytes), 'after-tracker-failure');

      expect(
        aliceChannel.relayHealth.where((health) => health.connected),
        hasLength(2),
      );
    });

    test('ignores replayed tracker offer', () async {
      await aliceChannel.publish(topic, utf8.encode('tracker-replay'));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final collected = collectFor(
        bobChannel.packets,
        const Duration(milliseconds: 400),
      );
      await relays.first.replayLastOffer();
      expect(await collected, isEmpty);
    });
  });
}

TrackerSignaling _channel(
  TestPeer peer,
  GroupSecret groupSecret,
  List<FakeTrackerRelay> relays,
) {
  return TrackerSignaling(
    security: peer.security(groupSecret),
    relays: TrackerRelayConfig(
      invitationRelays: relays.map((relay) => relay.uri),
      defaultRelays: const <Uri>[],
    ),
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
}
