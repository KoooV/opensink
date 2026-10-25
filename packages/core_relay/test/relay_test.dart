import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart' show CryptoSigner, generateIdentity;
import 'package:core_domain/core_domain.dart' hide RelayFrame;
import 'package:core_domain/core_domain.dart' as domain show RelayFrame;
import 'package:core_protocol/core_protocol.dart' show ProtoWriter, RelayFrame;
import 'package:core_relay/core_relay.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

PeerId peer(int value) {
  final bytes = Uint8List(32);
  bytes[0] = value;
  return PeerId(bytes);
}

Uint8List frameNonce(int value) {
  final bytes = Uint8List(16);
  bytes[0] = value;
  bytes[15] = value;
  return bytes;
}

class FakeClock {
  FakeClock(this._now);

  DateTime _now;

  DateTime call() => _now;

  void advance(Duration duration) => _now = _now.add(duration);
}

class Sent {
  Sent(this.dst, this.bytes, {this.relay = false});

  final PeerId dst;
  final Uint8List bytes;
  final bool relay;
}

class TestSigner implements Signer {
  TestSigner(this.localPeerId);

  final PeerId localPeerId;
  static final Map<String, String> registry = <String, String>{};

  String _key(PeerId peerId, Uint8List data) =>
      '${peerId.publicKey.join(',')}:${data.join(',')}';

  @override
  Future<String> sign(Uint8List data) async {
    final signature = sha512.convert(<int>[
      ...localPeerId.publicKey,
      ...data,
    ]).toString();
    registry[_key(localPeerId, data)] = signature;
    return signature;
  }

  @override
  Future<bool> verify(
    Uint8List data,
    String signatureHex,
    PeerId peerId,
  ) async => registry[_key(peerId, data)] == signatureHex;
}

class ScriptedTransport implements Transport {
  ScriptedTransport(this.localPeerId);

  final PeerId localPeerId;
  final _events = StreamController<PeerLinkEvent>.broadcast();
  final _relayIncoming = StreamController<RelayDatagram>.broadcast();
  final sent = <Sent>[];
  final reachable = <PeerId>{};
  final blackhole = <PeerId>{};

  @override
  Stream<PeerLinkEvent> get events => _events.stream;

  @override
  Stream<RelayDatagram> get relayIncoming => _relayIncoming.stream;

  @override
  Future<PeerLink> connect(PeerId peerId) async => FakePeerLink(peerId);

  @override
  Future<void> send(PeerId dst, List<int> bytes) =>
      _send(dst, bytes, relay: false);

  @override
  Future<void> sendRelay(PeerId dst, List<int> bytes) =>
      _send(dst, bytes, relay: true);

  Future<void> _send(
    PeerId dst,
    List<int> bytes, {
    required bool relay,
  }) async {
    if (blackhole.contains(dst)) {
      return Completer<void>().future;
    }
    if (!reachable.contains(dst)) {
      throw StateError('unreachable $dst');
    }
    sent.add(
      Sent(dst, Uint8List.fromList(bytes), relay: relay),
    );
  }

  void emitRelay(PeerId from, List<int> bytes) {
    _relayIncoming.add(
      RelayDatagram(
        from: from,
        bytes: bytes,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _relayIncoming.close();
    await _events.close();
  }
}

class SimNode {
  SimNode({
    required this.id,
    required this.topology,
    this.config = const RelayConfig(relayEnabled: true),
    DateTime Function()? clock,
    Signer? signer,
  }) {
    direct = ScriptedTransport(id);
    this.signer = signer ?? TestSigner(id);
    relay = RelayTransport(
      localPeerId: id,
      direct: direct,
      topology: topology,
      signer: this.signer,
      config: config,
      clock: clock,
    );
  }

  final PeerId id;
  final RelayTopology topology;
  final RelayConfig config;
  late final ScriptedTransport direct;
  late final Signer signer;
  late final RelayTransport relay;
  int read = 0;
}

RelayFrame? decodeFrame(Uint8List bytes) {
  final frame = RelayEnvelope.decode(bytes);
  if (frame == null || frame.dst.length != 32 || frame.src.length != 32) {
    return null;
  }
  return frame;
}

Future<Uint8List> signedEnvelope(
  SimNode origin,
  RelayFrame frame,
) async {
  final signature = await RelayFrameAuth.sign(frame, origin.signer);
  return RelayEnvelope.encode(frame.copyWith(signature: signature));
}

RelayConfig relayConfig({
  bool relayEnabled = true,
  int maxFrameBytes = 192 * 1024,
  int perSourceBurstBytes = 1024 * 1024,
  int perSourceBytesPerSecond = 64 * 1024,
  int seenMaxEntries = 4096,
  int maxSourceEntries = 256,
  int maxTrackedSources = 256,
  Duration directTimeout = const Duration(seconds: 5),
}) {
  return RelayConfig(
    relayEnabled: relayEnabled,
    maxFrameBytes: maxFrameBytes,
    perSourceBurstBytes: perSourceBurstBytes,
    perSourceBytesPerSecond: perSourceBytesPerSecond,
    seenMaxEntries: seenMaxEntries,
    maxSourceEntries: maxSourceEntries,
    maxTrackedSources: maxTrackedSources,
    directTimeout: directTimeout,
  );
}

Future<void> pump(List<SimNode> nodes, {Set<PeerId> dead = const {}}) async {
  var progressed = true;
  var guard = 0;
  while (progressed && guard++ < 32) {
    progressed = false;
    for (final node in nodes) {
      while (node.read < node.direct.sent.length) {
        final sent = node.direct.sent[node.read++];
        if (dead.contains(sent.dst)) {
          continue;
        }
        final frame = decodeFrame(sent.bytes);
        if (frame == null) {
          continue;
        }
        final target = nodes.where((candidate) => candidate.id == sent.dst);
        if (target.isEmpty) {
          continue;
        }
        progressed = true;
        await target.first.relay.accept(node.id, sent.bytes);
      }
    }
  }
}

void announce(
  RelayTopology topology,
  PeerId id, {
  required List<PeerId> neighbors,
  bool canRelay = true,
  int capacityBytesPerSecond = 1000,
  Duration rtt = const Duration(milliseconds: 20),
  int loadBytesPerSecond = 0,
}) {
  topology.applyPresence(
    id,
    neighbors: neighbors,
    canRelay: canRelay,
    capacityBytesPerSecond: capacityBytesPerSecond,
    rtt: rtt,
    loadBytesPerSecond: loadBytesPerSecond,
  );
}

void main() {
  group('RelayTopology', () {
    test('строит достижимость из presence и фильтрует по canRelay/возрасту', () {
      final clock = FakeClock(DateTime.utc(2026));
      final topology = RelayTopology(clock: clock.call, maxAge: const Duration(minutes: 1));
      final a = peer(1);
      final b = peer(2);
      final c = peer(3);
      final d = peer(4);

      announce(topology, c, neighbors: [a, b], rtt: const Duration(milliseconds: 40));
      announce(topology, d, neighbors: [a, b], canRelay: false);

      expect(
        topology.candidates(source: a, destination: b).map((p) => p.peerId),
        [c],
      );
      expect(topology.selectRelay(source: a, destination: b)?.peerId, c);

      clock.advance(const Duration(minutes: 2));
      expect(topology.candidates(source: a, destination: b), isEmpty);
    });

    test('выбирает релея по RTT и нагрузке', () {
      final topology = RelayTopology();
      final a = peer(1);
      final b = peer(2);
      final fast = peer(3);
      final loaded = peer(4);

      announce(topology, fast, neighbors: [a, b], rtt: const Duration(milliseconds: 50));
      announce(
        topology,
        loaded,
        neighbors: [a, b],
        capacityBytesPerSecond: 1000,
        rtt: const Duration(milliseconds: 10),
        loadBytesPerSecond: 900,
      );

      expect(topology.selectRelay(source: a, destination: b)?.peerId, fast);
    });
  });

  group('RelayTransport', () {
    test('предпочитает прямой путь', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      a.direct.reachable.add(b.id);

      final result = await a.relay.deliver(b.id, utf8.encode('hello'));

      expect(result, isA<DirectSent>());
      expect(a.direct.sent.single.dst, b.id);
      expect(a.relay.metrics.directSent, 1);
    });

    test('после таймаута ICE отправляет через релея', () async {
      final topology = RelayTopology();
      final a = SimNode(
        id: peer(1),
        topology: topology,
        config: const RelayConfig(
          relayEnabled: true,
          directTimeout: Duration(milliseconds: 5),
        ),
      );
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);

      announce(topology, c.id, neighbors: [a.id, b.id]);
      a.direct.blackhole.add(b.id);
      a.direct.reachable.add(c.id);
      c.direct.reachable.add(b.id);

      final received = b.relay.incoming.first;
      final result = await a.relay.deliver(b.id, utf8.encode('timeout'));

      expect(result, isA<RelayedSent>());
      expect((result as RelayedSent).relay, c.id);

      await pump([a, b, c]);
      expect((await received).payload, utf8.encode('timeout'));
    });

    test('A→B через C: payload непрозрачен для релея', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);

      announce(topology, c.id, neighbors: [a.id, b.id]);
      a.direct.reachable.add(c.id);
      c.direct.reachable.add(b.id);

      const plaintext = 'secret-message';
      final ciphertext = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef, 7, 8, 9]);

      final received = b.relay.incoming.first;
      final result = await a.relay.deliver(b.id, ciphertext);

      expect(result, isA<RelayedSent>());
      expect((result as RelayedSent).relay, c.id);

      await pump([a, b, c]);

      final forwarded = decodeFrame(c.direct.sent.single.bytes);
      expect(forwarded, isNotNull);
      expect(forwarded!.payload, ciphertext);
      expect(utf8.decode(forwarded.payload, allowMalformed: true), isNot(plaintext));
      expect(forwarded.src, a.id.publicKey);
      expect(forwarded.dst, b.id.publicKey);
      expect(forwarded.hopCount, 1);
      expect(forwarded.ttl, a.config.maxHops - 1);

      final inbound = await received;
      expect(inbound.src, a.id);
      expect(inbound.payload, ciphertext);
      expect(utf8.decode(inbound.payload, allowMalformed: true), isNot(plaintext));
    });

    test('пропажа релея: пересчёт на запасной путь, затем noRoute', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);
      final d = SimNode(id: peer(4), topology: topology);

      announce(topology, c.id, neighbors: [a.id, b.id], rtt: const Duration(milliseconds: 10));
      announce(topology, d.id, neighbors: [a.id, b.id], rtt: const Duration(milliseconds: 80));
      a.direct.reachable.addAll([c.id, d.id]);
      c.direct.reachable.add(b.id);
      d.direct.reachable.add(b.id);

      final first = b.relay.incoming.first;
      final initial = await a.relay.deliver(b.id, [1, 2, 3]);
      expect((initial as RelayedSent).relay, c.id);
      await pump([a, b, c, d]);
      expect((await first).payload, [1, 2, 3]);

      topology.remove(c.id);
      a.direct.reachable.remove(c.id);
      c.direct.reachable.remove(b.id);

      final second = b.relay.incoming.first;
      final rerouted = await a.relay.deliver(b.id, [4, 5, 6]);
      expect((rerouted as RelayedSent).relay, d.id);
      await pump([a, b, c, d], dead: {c.id});
      expect((await second).payload, [4, 5, 6]);

      topology.remove(d.id);
      a.direct.reachable.remove(d.id);

      final failed = await a.relay.deliver(b.id, [7, 8, 9]);
      expect(failed, isA<RelaySendFailed>());
      expect((failed as RelaySendFailed).reason, RelayFailureReason.noRoute);
    });

    test('кэш виденных кадров и TTL защищают от петель', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);

      announce(topology, c.id, neighbors: [a.id, b.id]);
      c.direct.reachable.add(b.id);

      RelayFrame frame(int payload, {int ttl = 2}) => RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: ttl,
        hopCount: 0,
        nonce: frameNonce(payload),
        payload: Uint8List.fromList([payload]),
      );

      await c.relay.accept(a.id, await signedEnvelope(a, frame(1)));
      await c.relay.accept(a.id, await signedEnvelope(a, frame(1)));

      expect(c.direct.sent, hasLength(1));
      expect(c.relay.metrics.forwarded, 1);
      expect(c.relay.metrics.droppedDuplicate, 1);

      await a.relay.accept(c.id, await signedEnvelope(c, frame(2)));
      expect(a.relay.metrics.droppedLoop, 1);

      await c.relay.accept(a.id, await signedEnvelope(a, frame(3, ttl: 0)));
      expect(c.relay.metrics.droppedTtl, 1);

      final forwarded = decodeFrame(c.direct.sent.first.bytes)!;
      expect(forwarded.ttl, 1);
      expect(forwarded.hopCount, 1);
    });

    test('лимит полосы на источник отбрасывает лишние кадры', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(
        id: peer(3),
        topology: topology,
        config: const RelayConfig(
          relayEnabled: true,
          maxFrameBytes: 200,
          perSourceBurstBytes: 250,
          perSourceBytesPerSecond: 1,
        ),
      );

      announce(topology, c.id, neighbors: [a.id, b.id]);
      c.direct.reachable.add(b.id);

      RelayFrame frame(List<int> payload) => RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(2),
        payload: Uint8List.fromList(payload),
      );

      await c.relay.accept(
        a.id,
        await signedEnvelope(a, frame(List<int>.filled(10, 1))),
      );
      await c.relay.accept(
        a.id,
        await signedEnvelope(a, frame(List<int>.filled(11, 2))),
      );

      expect(c.relay.metrics.forwarded, 1);
      expect(c.relay.metrics.droppedRateLimited, 1);
      expect(c.direct.sent, hasLength(1));
    });

    test('opt-in: выключенный ретранслятор не пересылает', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(
        id: peer(3),
        topology: topology,
        config: const RelayConfig(relayEnabled: false),
      );

      announce(topology, c.id, neighbors: [a.id, b.id]);
      c.direct.reachable.add(b.id);

      final frame = RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(3),
        payload: Uint8List.fromList([1, 2, 3]),
      );
      await c.relay.accept(a.id, await signedEnvelope(a, frame));

      expect(c.direct.sent, isEmpty);
      expect(c.relay.metrics.droppedDisabled, 1);
    });

    test('RelayOptIn: Android по умолчанию осторожен', () {
      expect(
        const RelayOptIn().shouldEnable(
          platform: RelayPlatform.android,
          userConsent: true,
          metered: true,
          batteryLevel: 0.8,
        ),
        isFalse,
      );
      expect(
        const RelayOptIn().shouldEnable(
          platform: RelayPlatform.android,
          userConsent: true,
          metered: false,
          batteryLevel: 0.1,
        ),
        isFalse,
      );
      expect(
        const RelayOptIn().shouldEnable(
          platform: RelayPlatform.android,
          userConsent: true,
          metered: false,
          batteryLevel: 0.8,
        ),
        isTrue,
      );
      expect(
        const RelayOptIn().shouldEnable(
          platform: RelayPlatform.linux,
          userConsent: false,
          metered: false,
          batteryLevel: 1,
        ),
        isFalse,
      );
    });
  });


  group('R-01…R-09: hardening', () {
    test('R-01: первый хоп требует from == src и ключует лимит по from',
        () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);
      announce(topology, c.id, neighbors: [a.id, b.id]);

      final spoofed = RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(4),
        payload: Uint8List.fromList([1, 2, 3]),
      );
      await c.relay.accept(b.id, await signedEnvelope(a, spoofed));

      expect(c.direct.sent, isEmpty);
      expect(c.relay.metrics.droppedUnauthenticated, 1);
    });

    test('R-01: src == localPeerId отбрасывается как петля', () async {
      final topology = RelayTopology();
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);

      final loop = RelayFrame(
        dst: b.id.publicKey,
        src: c.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(5),
        payload: Uint8List.fromList([1]),
      );
      await c.relay.accept(c.id, await signedEnvelope(c, loop));

      expect(c.direct.sent, isEmpty);
      expect(c.relay.metrics.droppedLoop, 1);
    });

    test('R-02: кэши источников и метрики ограничены (LRU)', () async {
      final metrics = RelayMetrics(maxTrackedSources: 2);
      metrics.recordForward(peer(1), 1);
      metrics.recordForward(peer(2), 2);
      metrics.recordForward(peer(3), 3);
      expect(metrics.forwardedBytesBySource.length, 2);
      expect(
        metrics.forwardedBytesBySource.containsKey(peer(1)),
        isFalse,
      );

      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(
        id: peer(3),
        topology: topology,
        config: relayConfig(maxSourceEntries: 1),
      );
      announce(topology, c.id, neighbors: [a.id, b.id]);
      c.direct.reachable.add(b.id);

      for (final origin in [a, b]) {
        final frame = RelayFrame(
          dst: b.id.publicKey,
          src: origin.id.publicKey,
          ttl: 2,
          hopCount: 0,
          nonce: frameNonce(6),
          payload: Uint8List.fromList([origin.id.publicKey[0]]),
        );
        await c.relay.accept(
          origin.id,
          await signedEnvelope(origin, frame),
        );
      }
      expect(c.relay.trackedSourceCount, 1);
    });

    test('R-03: maxPayload и полный размер кадра ограничены', () async {
      final topology = RelayTopology();
      final a = SimNode(
        id: peer(1),
        topology: topology,
        config: relayConfig(maxFrameBytes: 140),
      );
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(
        id: peer(3),
        topology: topology,
        config: relayConfig(maxFrameBytes: 140),
      );
      announce(topology, c.id, neighbors: [a.id, b.id]);
      a.direct.reachable.add(c.id);

      final tooLarge = await a.relay.deliver(
        b.id,
        List<int>.filled(a.config.maxPayloadBytes + 1, 1),
      );
      expect(tooLarge, isA<RelaySendFailed>());
      expect(
        (tooLarge as RelaySendFailed).reason,
        RelayFailureReason.frameTooLarge,
      );

      await c.relay.accept(
        a.id,
        Uint8List(a.config.maxFrameBytes + 1),
      );
      expect(c.relay.metrics.droppedOversize, 1);
    });

    test('R-04: token bucket по from применяется и к локальной доставке',
        () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(
        id: peer(2),
        topology: topology,
        config: relayConfig(
          maxFrameBytes: 200,
          perSourceBurstBytes: 250,
          perSourceBytesPerSecond: 1,
        ),
      );

      RelayFrame frame(int tag) => RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(7),
        payload: Uint8List.fromList(List<int>.filled(10, tag)),
      );

      await b.relay.accept(a.id, await signedEnvelope(a, frame(1)));
      await b.relay.accept(a.id, await signedEnvelope(a, frame(2)));

      expect(b.relay.metrics.delivered, 1);
      expect(b.relay.metrics.droppedRateLimited, 1);
    });

    test('R-05: unknown-поля списываются и отбрасываются при пересылке',
        () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(
        id: peer(3),
        topology: topology,
        config: relayConfig(
          maxFrameBytes: 4096,
          perSourceBurstBytes: 150,
          perSourceBytesPerSecond: 1,
        ),
      );
      announce(topology, c.id, neighbors: [a.id, b.id]);
      c.direct.reachable.add(b.id);

      Uint8List frameWithUnknown() {
        final writer = ProtoWriter();
        writer.writeBytesField(1, b.id.publicKey);
        writer.writeBytesField(2, a.id.publicKey);
        writer.writeVarintField(3, 2);
        writer.writeVarintField(4, 0);
        writer.writeBytesField(5, Uint8List.fromList([1, 2, 3]));
        writer.writeBytesField(7, frameNonce(90));
        writer.writeBytesField(99, Uint8List(100));
        return writer.finish();
      }

      final raw = frameWithUnknown();
      final unsigned = RelayFrame.fromBytes(raw);
      final encoded = await signedEnvelope(a, unsigned);
      expect(encoded.length, greaterThan(150));
      await c.relay.accept(a.id, encoded);
      expect(c.relay.metrics.droppedRateLimited, 1);

      final charged = SimNode(
        id: peer(4),
        topology: topology,
        config: relayConfig(maxFrameBytes: 4096),
      );
      announce(topology, charged.id, neighbors: [a.id, b.id]);
      charged.direct.reachable.add(b.id);
      await charged.relay.accept(a.id, encoded);
      expect(charged.relay.metrics.forwarded, 1);
      final forwarded = charged.direct.sent.single.bytes;
      expect(forwarded.length, lessThan(encoded.length));
      expect(RelayEnvelope.decode(forwarded), isNotNull);
    });

    test('R-06: seen фиксируется после успеха, пустой кэш не падает',
        () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(
        id: peer(3),
        topology: topology,
        config: relayConfig(seenMaxEntries: 8),
      );
      final d = SimNode(id: peer(4), topology: topology);
      final e = SimNode(id: peer(5), topology: topology);

      announce(
        topology,
        d.id,
        neighbors: [c.id, b.id],
        rtt: const Duration(milliseconds: 5),
      );
      announce(
        topology,
        e.id,
        neighbors: [c.id, b.id],
        rtt: const Duration(milliseconds: 50),
      );
      c.direct.blackhole.add(d.id);
      c.direct.reachable.add(e.id);

      final frame = RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(8),
        payload: Uint8List.fromList([7]),
      );
      final bytes = await signedEnvelope(a, frame);

      await c.relay.accept(a.id, bytes);
      expect(c.relay.metrics.forwardFailed, 1);
      await c.relay.accept(a.id, bytes);
      expect(c.relay.metrics.forwarded, 1);
      await c.relay.accept(a.id, bytes);
      expect(c.direct.sent, hasLength(1));

      final emptyCache = SimNode(
        id: peer(6),
        topology: topology,
        config: relayConfig(seenMaxEntries: 0),
      );
      final localFrame = await signedEnvelope(
        a,
        RelayFrame(
          dst: emptyCache.id.publicKey,
          src: a.id.publicKey,
          ttl: 2,
          hopCount: 0,
          nonce: frameNonce(9),
          payload: Uint8List.fromList([8]),
        ),
      );
      await emptyCache.relay.accept(a.id, localFrame);
      await emptyCache.relay.accept(a.id, localFrame);
      expect(emptyCache.relay.metrics.delivered, 2);
    });

    test('R-07: MemberRelay пробрасывает ошибку доставки', () async {
      final topology = RelayTopology();
      final a = SimNode(
        id: peer(1),
        topology: topology,
        config: relayConfig(),
      );
      final b = SimNode(id: peer(2), topology: topology);
      final relay = MemberRelay(transport: a.relay, topology: topology);

      await expectLater(
        relay.forward(
          domain.RelayFrame(
            src: a.id,
            dst: b.id,
            payload: Uint8List.fromList([1]),
          ),
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        relay.forward(
          domain.RelayFrame(
            src: b.id,
            dst: b.id,
            payload: Uint8List.fromList([1]),
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('R-08: принимаются только тегированные relay-кадры', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);

      announce(topology, c.id, neighbors: [a.id, b.id]);
      a.direct.reachable.add(c.id);
      c.direct.reachable.add(b.id);

      final plane = RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(10),
        payload: Uint8List.fromList([1]),
      );
      await c.relay.accept(a.id, plane.toBytes());
      expect(c.relay.metrics.droppedMalformed, 1);

      await a.relay.deliver(b.id, [1, 2, 3]);
      expect(RelayEnvelope.isEnvelope(a.direct.sent.single.bytes), isTrue);
      expect(a.direct.sent.single.relay, isTrue);

      final signed = await signedEnvelope(
        a,
        RelayFrame(
          dst: b.id.publicKey,
          src: a.id.publicKey,
          ttl: 2,
          hopCount: 0,
          nonce: frameNonce(11),
          payload: Uint8List.fromList([9]),
        ),
      );
      c.direct.emitRelay(a.id, signed);
      await Future<void>.delayed(Duration.zero);
      expect(c.relay.metrics.forwarded, 1);
    });


    test('подпись отвергает unsigned, чужой src и изменённые поля', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);
      announce(topology, c.id, neighbors: [a.id, b.id]);
      c.direct.reachable.add(b.id);

      final base = RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(12),
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final valid = await signedEnvelope(a, base);

      await c.relay.accept(a.id, RelayEnvelope.encode(base));
      expect(c.relay.metrics.droppedMalformed, 1);

      final signedFrame = RelayEnvelope.decode(valid)!;
      final badSignature = RelayEnvelope.encode(
        signedFrame.copyWith(signature: Uint8List(64)),
      );
      await c.relay.accept(a.id, badSignature);
      expect(c.relay.metrics.droppedBadSignature, 1);

      final tamperedPayload = RelayEnvelope.encode(
        signedFrame.copyWith(payload: Uint8List.fromList([9, 9, 9])),
      );
      await c.relay.accept(a.id, tamperedPayload);
      expect(c.relay.metrics.droppedBadSignature, 2);

      final tamperedDst = RelayEnvelope.encode(
        signedFrame.copyWith(dst: peer(7).publicKey),
      );
      await c.relay.accept(a.id, tamperedDst);
      expect(c.relay.metrics.droppedBadSignature, 3);

      final tamperedTtl = RelayEnvelope.encode(
        signedFrame.copyWith(ttl: 1),
      );
      await c.relay.accept(a.id, tamperedTtl);
      expect(c.relay.metrics.droppedBadSignature, 4);

      final wrongOrigin = await signedEnvelope(b, base);
      await c.relay.accept(a.id, wrongOrigin);
      expect(c.relay.metrics.droppedBadSignature, 5);

      expect(c.direct.sent, isEmpty);
    });

    test('nonce различает одинаковый payload, replay по nonce отсекается',
        () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);
      announce(topology, c.id, neighbors: [a.id, b.id]);
      c.direct.reachable.add(b.id);

      RelayFrame frame(int nonce) => RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(nonce),
        payload: Uint8List.fromList([1, 2, 3]),
      );

      final first = await signedEnvelope(a, frame(1));
      final second = await signedEnvelope(a, frame(2));
      await c.relay.accept(a.id, first);
      await c.relay.accept(a.id, first);
      await c.relay.accept(a.id, second);

      expect(c.relay.metrics.forwarded, 2);
      expect(c.relay.metrics.droppedDuplicate, 1);
    });

    test('реальный Ed25519 signer проходит A→C→B через relay-канал',
        () async {
      final alice = await generateIdentity();
      final bob = await generateIdentity();
      final carol = await generateIdentity();
      final topology = RelayTopology();
      final a = SimNode(
        id: alice.peerId,
        topology: topology,
        signer: CryptoSigner(alice.ed25519PrivateKey),
      );
      final b = SimNode(
        id: bob.peerId,
        topology: topology,
        signer: CryptoSigner(bob.ed25519PrivateKey),
      );
      final c = SimNode(
        id: carol.peerId,
        topology: topology,
        signer: CryptoSigner(carol.ed25519PrivateKey),
      );
      announce(topology, c.id, neighbors: [a.id, b.id]);
      a.direct.reachable.add(c.id);
      c.direct.reachable.add(b.id);

      final received = b.relay.incoming.first;
      final result = await a.relay.deliver(b.id, [7, 8, 9]);
      expect(result, isA<RelayedSent>());
      expect(a.direct.sent.single.relay, isTrue);
      await pump([a, b, c]);
      expect((await received).payload, [7, 8, 9]);
      expect(c.direct.sent.single.relay, isTrue);
    });
    test('R-09: ретрансляция по умолчанию выключена', () async {
      const config = RelayConfig(directTimeout: Duration(milliseconds: 5));
      expect(config.relayEnabled, isFalse);
      expect(config.perSourceBurstBytes, greaterThanOrEqualTo(config.maxFrameBytes));

      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology, config: config);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);
      announce(topology, c.id, neighbors: [a.id, b.id]);

      final result = await a.relay.deliver(b.id, [1]);
      expect(result, isA<RelaySendFailed>());
      expect((result as RelaySendFailed).reason, RelayFailureReason.disabled);
    });
  });

  test('MemberRelay реализует доменный Relay', () async {
    final topology = RelayTopology();
    final a = SimNode(id: peer(1), topology: topology);
    final b = SimNode(id: peer(2), topology: topology);
    a.direct.reachable.add(b.id);
    announce(topology, a.id, neighbors: [b.id], canRelay: false);

    final relay = MemberRelay(transport: a.relay, topology: topology);

    expect(relay.capacity, a.config.perSourceBytesPerSecond);
    expect(relay.routes(b.id), isTrue);
    expect(relay.routes(peer(9)), isFalse);

    await relay.forward(
      domain.RelayFrame(
        src: a.id,
        dst: b.id,
        payload: Uint8List.fromList([42]),
      ),
    );

    expect(a.direct.sent.single.dst, b.id);
    expect(a.direct.sent.single.bytes, [42]);
  });
}
