@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_signaling/core_signaling.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';

import 'support/fake_nostr_relay.dart';
import 'support/test_helpers.dart';

void main() {
  group('NostrSignaling', () {
    late List<FakeNostrRelay> relays;
    late GroupSecret groupSecret;
    late TestPeer alice;
    late TestPeer bob;
    late NostrSignaling aliceChannel;
    late NostrSignaling bobChannel;
    late String topic;

    setUp(() async {
      relays = <FakeNostrRelay>[
        await FakeNostrRelay.start(),
        await FakeNostrRelay.start(),
        await FakeNostrRelay.start(),
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
        reason: 'both clients must connect to all relays',
      );
    });

    tearDown(() async {
      await aliceChannel.close();
      await bobChannel.close();
      for (final relay in relays) {
        await relay.stop();
      }
    });

    test('exchanges presence and SDP with deduplication', () async {
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
      expect(seen.capabilities.publicIpv6, '2001:db8::1');
      expect(seen.capabilities.canRelay, isTrue);

      final offerFuture = bobChannel.incoming.first.timeout(
        const Duration(seconds: 5),
      );
      await aliceChannel.publish(topic, utf8.encode('offer-sdp'));
      final offer = await offerFuture;
      expect(offer.from, alice.peerId);
      expect(utf8.decode(offer.bytes), 'offer-sdp');

      final answerFuture = aliceChannel.incoming.first.timeout(
        const Duration(seconds: 5),
      );
      await bobChannel.publishTo(
        topic,
        kind: SignalingKind.answer,
        to: alice.peerId,
        bytes: utf8.encode('answer-sdp'),
      );
      final answer = await answerFuture;
      expect(answer.from, bob.peerId);
      expect(utf8.decode(answer.bytes), 'answer-sdp');

      final collected = collectFor(
        bobChannel.packets,
        const Duration(milliseconds: 400),
      );
      await aliceChannel.publish(topic, utf8.encode('dedup-me'));
      expect(await collected, hasLength(1));
    });

    test('uses NIP-01 ephemeral kind and hashed topic filter', () async {
      final expectedTag = crypto.sha256.convert(utf8.encode(topic)).toString();

      await waitFor(
        () => relays.first.lastFilter != null,
        timeout: const Duration(seconds: 5),
        reason: 'relay must receive REQ after join',
      );
      final filter = relays.first.lastFilter!;
      expect(filter['kinds'], contains(NostrSignaling.ephemeralKind));
      expect(
        NostrSignaling.ephemeralKind,
        inInclusiveRange(
          NostrSignaling.ephemeralKindMin,
          NostrSignaling.ephemeralKindMax,
        ),
      );
      expect(filter['#t'], <String>[expectedTag]);
      expect(filter['limit'], isA<int>());

      await waitFor(
        () => relays.first.lastEvent != null,
        timeout: const Duration(seconds: 5),
        reason: 'relay must receive at least one hello event',
      );
      final event = relays.first.lastEvent!;
      expect(event['kind'], NostrSignaling.ephemeralKind);
      expect(event['id'], hasLength(64));
      expect(event['pubkey'], hasLength(64));
      expect(event['sig'], hasLength(128));
      expect(event['content'], isA<String>());
      final tags = event['tags'] as List;
      expect(
        tags.any(
          (tag) =>
              tag is List &&
              tag.length >= 2 &&
              tag[0] == 't' &&
              tag[1] == expectedTag,
        ),
        isTrue,
      );
    });

    test('survives one relay failure', () async {
      await relays.first.stop();
      await waitFor(
        () =>
            aliceChannel.connectedRelayCount == 2 &&
            bobChannel.connectedRelayCount == 2,
        timeout: const Duration(seconds: 10),
        reason: 'clients must fail over to remaining relays',
      );
      final offerFuture = bobChannel.incoming.first.timeout(
        const Duration(seconds: 5),
      );
      await aliceChannel.publish(topic, utf8.encode('after-failure'));
      final offer = await offerFuture;
      expect(utf8.decode(offer.bytes), 'after-failure');

      expect(aliceChannel.relayHealth, hasLength(3));
      expect(
        aliceChannel.relayHealth.where((health) => health.connected),
        hasLength(2),
      );
    });

    test('ignores replayed relay event', () async {
      await aliceChannel.publish(topic, utf8.encode('replay-target'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final collected = collectFor(
        bobChannel.packets,
        const Duration(milliseconds: 400),
      );
      await relays.first.replayLastEvent();
      expect(await collected, isEmpty);
    });

    test('rejects publication from a peer with another group secret', () async {
      final carol = await TestPeer.create();
      final otherSecret = await GroupSecret.random();
      final carolChannel = _channel(carol, otherSecret, relays);
      await carolChannel.join(topic);
      await waitFor(
        () => carolChannel.connectedRelayCount == relays.length,
        timeout: const Duration(seconds: 10),
      );
      final collected = collectFor(
        bobChannel.packets,
        const Duration(milliseconds: 400),
      );
      await carolChannel.publish(topic, utf8.encode('not-a-member'));
      expect(await collected, isEmpty);
      await carolChannel.close();
    });
  });
}

NostrSignaling _channel(
  TestPeer peer,
  GroupSecret groupSecret,
  List<FakeNostrRelay> relays,
) {
  return NostrSignaling(
    security: peer.security(groupSecret),
    relays: NostrRelayConfig(
      invitationRelays: relays.map((relay) => relay.uri),
      defaultRelays: const <Uri>[],
    ),
    capabilities: peer.capabilities(),
    helloInterval: const Duration(seconds: 5),
    presenceTtl: const Duration(seconds: 30),
    reconnectPolicy: const ReconnectPolicy(
      baseDelay: Duration(milliseconds: 50),
      maxDelay: Duration(milliseconds: 500),
      connectTimeout: Duration(seconds: 2),
    ),
  );
}
