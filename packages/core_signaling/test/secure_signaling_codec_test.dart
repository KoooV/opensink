@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_signaling/core_signaling.dart';
import 'package:test/test.dart';

import 'support/test_helpers.dart';

void main() {
  const topic = 'topic-a';

  late TestPeer alice;
  late TestPeer bob;
  late GroupSecret groupSecret;
  late SecureSignalingCodec aliceCodec;
  late SecureSignalingCodec bobCodec;

  setUp(() async {
    alice = await TestPeer.create();
    bob = await TestPeer.create();
    groupSecret = await GroupSecret.random();
    final allowed = <PeerId>{alice.peerId, bob.peerId};
    aliceCodec = SecureSignalingCodec(
      security: SignalingSecurityConfig(
        peerId: alice.peerId,
        signer: alice.signer,
        groupSecret: groupSecret,
        allowedPeers: allowed,
      ),
    );
    bobCodec = SecureSignalingCodec(
      security: SignalingSecurityConfig(
        peerId: bob.peerId,
        signer: bob.signer,
        groupSecret: groupSecret,
        allowedPeers: allowed,
      ),
    );
  });

  test('roundtrips offer with recipient', () async {
    final packet = await aliceCodec.seal(
      topic: topic,
      kind: SignalingKind.offer,
      to: bob.peerId,
      body: utf8.encode('v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n'),
    );
    final result = await bobCodec.open(packet, topic: topic);
    expect(result, isA<OpenSignalingOk>());
    final opened = (result as OpenSignalingOk).value;
    expect(opened.kind, SignalingKind.offer);
    expect(opened.from, alice.peerId);
    expect(opened.to, bob.peerId);
    expect(utf8.decode(opened.body), startsWith('v=0'));
  });

  test('roundtrips broadcast without recipient', () async {
    final packet = await aliceCodec.seal(
      topic: topic,
      kind: SignalingKind.ice,
      body: utf8.encode('candidate:1 1 udp 1 127.0.0.1 5000 typ host'),
    );
    final result = await bobCodec.open(packet, topic: topic);
    expect(result, isA<OpenSignalingOk>());
    expect((result as OpenSignalingOk).value.to, isNull);
  });

  test('rejects tampered signature', () async {
    final packet = await aliceCodec.seal(
      topic: topic,
      kind: SignalingKind.offer,
      body: const <int>[1, 2, 3],
    );
    packet[packet.length - 1] ^= 0xFF;
    final result = await bobCodec.open(packet, topic: topic);
    expect(result, isA<OpenSignalingRejected>());
    expect(
      (result as OpenSignalingRejected).reason,
      SignalingReject.badSignature,
    );
  });

  test('rejects packet for another recipient', () async {
    final carol = await TestPeer.create();
    final packet = await aliceCodec.seal(
      topic: topic,
      kind: SignalingKind.offer,
      to: carol.peerId,
      body: const <int>[1],
    );
    final result = await bobCodec.open(packet, topic: topic);
    expect((result as OpenSignalingRejected).reason, SignalingReject.notForMe);
  });

  test('rejects replay of the same nonce', () async {
    final packet = await aliceCodec.seal(
      topic: topic,
      kind: SignalingKind.offer,
      body: const <int>[1],
    );
    expect(await bobCodec.open(packet, topic: topic), isA<OpenSignalingOk>());
    final replay = await bobCodec.open(packet, topic: topic);
    expect((replay as OpenSignalingRejected).reason, SignalingReject.replayed);
  });

  test('rejects own echo', () async {
    final packet = await aliceCodec.seal(
      topic: topic,
      kind: SignalingKind.offer,
      body: const <int>[1],
    );
    final result = await aliceCodec.open(packet, topic: topic);
    expect((result as OpenSignalingRejected).reason, SignalingReject.selfEcho);
  });

  test('rejects sender outside allowedPeers', () async {
    final carol = await TestPeer.create();
    final carolCodec = SecureSignalingCodec(
      security: SignalingSecurityConfig(
        peerId: carol.peerId,
        signer: carol.signer,
        groupSecret: groupSecret,
      ),
    );
    final packet = await carolCodec.seal(
      topic: topic,
      kind: SignalingKind.offer,
      body: const <int>[1],
    );
    final result = await bobCodec.open(packet, topic: topic);
    expect(
      (result as OpenSignalingRejected).reason,
      SignalingReject.unauthorized,
    );
  });

  test('rejects sender when isAuthorized returns false', () async {
    final codec = SecureSignalingCodec(
      security: SignalingSecurityConfig(
        peerId: bob.peerId,
        signer: bob.signer,
        groupSecret: groupSecret,
        isAuthorized: (_) async => false,
      ),
    );
    final packet = await aliceCodec.seal(
      topic: topic,
      kind: SignalingKind.offer,
      body: const <int>[1],
    );
    final result = await codec.open(packet, topic: topic);
    expect(
      (result as OpenSignalingRejected).reason,
      SignalingReject.unauthorized,
    );
  });

  test('rejects stale timestamp outside clock skew', () async {
    final staleCodec = SecureSignalingCodec(
      security: SignalingSecurityConfig(
        peerId: alice.peerId,
        signer: alice.signer,
        groupSecret: groupSecret,
      ),
      clock: () => DateTime.now().subtract(const Duration(minutes: 10)),
    );
    final packet = await staleCodec.seal(
      topic: topic,
      kind: SignalingKind.offer,
      body: const <int>[1],
    );
    final result = await bobCodec.open(packet, topic: topic);
    expect((result as OpenSignalingRejected).reason, SignalingReject.expired);
  });

  test('rejects packet moved to another topic', () async {
    final packet = await aliceCodec.seal(
      topic: topic,
      kind: SignalingKind.offer,
      body: const <int>[1],
    );
    final result = await bobCodec.open(packet, topic: 'topic-b');
    expect(result, isA<OpenSignalingRejected>());
    expect(
      (result as OpenSignalingRejected).reason,
      SignalingReject.undecryptable,
    );
  });

  test('rejects packet encrypted with another group secret', () async {
    final otherSecret = await GroupSecret.random();
    final otherCodec = SecureSignalingCodec(
      security: SignalingSecurityConfig(
        peerId: alice.peerId,
        signer: alice.signer,
        groupSecret: otherSecret,
      ),
    );
    final packet = await otherCodec.seal(
      topic: topic,
      kind: SignalingKind.offer,
      body: const <int>[1],
    );
    final result = await bobCodec.open(packet, topic: topic);
    expect(
      (result as OpenSignalingRejected).reason,
      SignalingReject.undecryptable,
    );
  });

  test('rejects malformed, wrong version and oversize packets', () async {
    final short = await bobCodec.open(
      Uint8List.fromList(<int>[1, 2, 3]),
      topic: topic,
    );
    expect((short as OpenSignalingRejected).reason, SignalingReject.malformed);

    final packet = await aliceCodec.seal(
      topic: topic,
      kind: SignalingKind.offer,
      body: const <int>[1],
    );
    packet[4] = 9;
    final wrongVersion = await bobCodec.open(packet, topic: topic);
    expect(
      (wrongVersion as OpenSignalingRejected).reason,
      SignalingReject.badVersion,
    );

    final oversize = await bobCodec.open(Uint8List(300 * 1024), topic: topic);
    expect(
      (oversize as OpenSignalingRejected).reason,
      SignalingReject.tooLarge,
    );
  });

  test('rate limits incoming packets', () async {
    const limits = SignalingLimits(
      rateCapacity: 2,
      rateRefillPerSecond: 0,
      perSenderRateCapacity: 2,
      perSenderRefillPerSecond: 0,
    );
    final limitedAlice = SecureSignalingCodec(
      security: SignalingSecurityConfig(
        peerId: alice.peerId,
        signer: alice.signer,
        groupSecret: groupSecret,
      ),
      limits: limits,
    );
    final limitedBob = SecureSignalingCodec(
      security: SignalingSecurityConfig(
        peerId: bob.peerId,
        signer: bob.signer,
        groupSecret: groupSecret,
      ),
      limits: limits,
    );
    final packets = <Uint8List>[
      for (var i = 0; i < 3; i++)
        await limitedAlice.seal(
          topic: topic,
          kind: SignalingKind.offer,
          body: <int>[i],
        ),
    ];
    expect(
      await limitedBob.open(packets[0], topic: topic),
      isA<OpenSignalingOk>(),
    );
    expect(
      await limitedBob.open(packets[1], topic: topic),
      isA<OpenSignalingOk>(),
    );
    final third = await limitedBob.open(packets[2], topic: topic);
    expect(
      (third as OpenSignalingRejected).reason,
      SignalingReject.rateLimited,
    );
  });

  test('hello capabilities roundtrip', () {
    final capabilities = NodeCapabilities(
      platform: SignalingPlatform.android,
      publicIpv6: '2001:db8::42',
      uptime: const Duration(hours: 2),
      canRelay: true,
      canSfu: true,
      neighbors: <PeerId>[alice.peerId],
    );
    final encoded = SecureSignalingCodec.encodeHello(capabilities);
    final decoded = SecureSignalingCodec.decodeHello(encoded);
    expect(decoded, isNotNull);
    expect(decoded!.platform, SignalingPlatform.android);
    expect(decoded.publicIpv6, '2001:db8::42');
    expect(decoded.uptime, const Duration(hours: 2));
    expect(decoded.canRelay, isTrue);
    expect(decoded.canSfu, isTrue);
    expect(decoded.neighbors.single, alice.peerId);
  });
}
