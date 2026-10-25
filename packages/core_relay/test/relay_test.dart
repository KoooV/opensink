import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart'
    show CryptoSigner, generateIdentity;
import 'package:core_domain/core_domain.dart' hide RelayFrame;
import 'package:core_domain/core_domain.dart' as domain show RelayFrame;
import 'package:core_protocol/core_protocol.dart' show ProtoWriter, RelayFrame;
import 'package:core_relay/core_relay.dart';
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

class FakeMonotonic {
  Duration _elapsed = Duration.zero;

  Duration call() => _elapsed;

  void advance(Duration duration) => _elapsed += duration;
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
    final signature = List<int>.generate(64, (i) {
      var value = localPeerId.publicKey[i % localPeerId.publicKey.length];
      for (var j = i; j < data.length; j += 64) {
        value ^= data[j];
      }
      return value & 0xff;
    }).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    registry[_key(localPeerId, data)] = signature;
    return signature;
  }

  @override
  Future<bool> verify(
    Uint8List data,
    String signatureHex,
    PeerId peerId,
  ) async =>
      _constantTimeEquals(registry[_key(peerId, data)] ?? '', signatureHex);

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}

class ScriptedTransport implements Transport {
  ScriptedTransport(this.localPeerId);

  final PeerId localPeerId;
  final _events = StreamController<PeerLinkEvent>.broadcast();
  final _relayIncoming = StreamController<RelayDatagram>.broadcast();
  final sent = <Sent>[];
  final reachable = <PeerId>{};
  final blackhole = <PeerId>{};
  bool closed = false;
  int closeCount = 0;

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

  Future<void> _send(PeerId dst, List<int> bytes, {required bool relay}) async {
    if (blackhole.contains(dst)) {
      return Completer<void>().future;
    }
    if (!reachable.contains(dst)) {
      throw StateError('unreachable $dst');
    }
    sent.add(Sent(dst, Uint8List.fromList(bytes), relay: relay));
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

  void finishEvents() => _events.close();

  void failEvents(Object error) => _events.addError(error);

  @override
  Future<void> close() async {
    closeCount += 1;
    closed = true;
    if (!_relayIncoming.isClosed) {
      await _relayIncoming.close();
    }
    if (!_events.isClosed) {
      await _events.close();
    }
  }
}

class SimNode {
  SimNode({
    required this.id,
    required this.topology,
    this.config = const RelayConfig(relayEnabled: true),
    DateTime Function()? clock,
    Duration Function()? monotonicClock,
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
      monotonicClock: monotonicClock,
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

Future<Uint8List> signedEnvelope(SimNode origin, RelayFrame frame) async {
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
  int incomingBufferFrames = 64,
  Duration directTimeout = const Duration(seconds: 5),
  Duration forwardTimeout = const Duration(seconds: 5),
  Duration seenTtl = const Duration(minutes: 5),
}) {
  return RelayConfig(
    relayEnabled: relayEnabled,
    maxFrameBytes: maxFrameBytes,
    perSourceBurstBytes: perSourceBurstBytes,
    perSourceBytesPerSecond: perSourceBytesPerSecond,
    seenMaxEntries: seenMaxEntries,
    maxSourceEntries: maxSourceEntries,
    maxTrackedSources: maxTrackedSources,
    incomingBufferFrames: incomingBufferFrames,
    directTimeout: directTimeout,
    forwardTimeout: forwardTimeout,
    seenTtl: seenTtl,
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
  setUp(TestSigner.registry.clear);

  group('RelayTopology', () {
    test(
      'строит достижимость из presence и фильтрует по canRelay/возрасту',
      () {
        final clock = FakeClock(DateTime.utc(2026));
        final topology = RelayTopology(
          clock: clock.call,
          maxAge: const Duration(minutes: 1),
        );
        final a = peer(1);
        final b = peer(2);
        final c = peer(3);
        final d = peer(4);

        announce(
          topology,
          c,
          neighbors: [a, b],
          rtt: const Duration(milliseconds: 40),
        );
        announce(topology, d, neighbors: [a, b], canRelay: false);

        expect(
          topology.candidates(source: a, destination: b).map((p) => p.peerId),
          [c],
        );
        expect(topology.selectRelay(source: a, destination: b)?.peerId, c);

        clock.advance(const Duration(minutes: 2));
        expect(topology.candidates(source: a, destination: b), isEmpty);
      },
    );

    test('выбирает релея по RTT и нагрузке', () {
      final topology = RelayTopology();
      final a = peer(1);
      final b = peer(2);
      final fast = peer(3);
      final loaded = peer(4);

      announce(
        topology,
        fast,
        neighbors: [a, b],
        rtt: const Duration(milliseconds: 50),
      );
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

    test('R-11: старый и повторный presence не откатывают маршруты', () {
      final clock = FakeClock(DateTime.utc(2026));
      final topology = RelayTopology(
        clock: clock.call,
        maxAge: const Duration(minutes: 1),
      );
      final a = peer(1);
      final b = peer(2);
      final c = peer(3);
      final d = peer(4);
      final now = clock();

      topology.applyPresence(
        c,
        neighbors: [a, b],
        canRelay: true,
        capacityBytesPerSecond: 1000,
        rtt: const Duration(milliseconds: 20),
        at: now,
      );
      topology.applyPresence(
        c,
        neighbors: [a, d],
        canRelay: false,
        rtt: const Duration(milliseconds: 1),
        at: now.subtract(const Duration(seconds: 1)),
      );
      topology.applyPresence(
        c,
        neighbors: [a, d],
        canRelay: false,
        rtt: const Duration(milliseconds: 1),
        at: now,
      );

      expect(topology.infoFor(c)?.neighbors, {a, b});
      expect(topology.infoFor(c)?.canRelay, isTrue);
      expect(topology.candidates(source: a, destination: b), hasLength(1));
      expect(topology.selectRelay(source: a, destination: b)?.peerId, c);
    });

    test('R-11: будущий updatedAt ограничен временем получения', () {
      final clock = FakeClock(DateTime.utc(2026));
      final topology = RelayTopology(
        clock: clock.call,
        maxAge: const Duration(minutes: 1),
      );
      final a = peer(1);
      final b = peer(2);
      final c = peer(3);
      final now = clock();

      topology.applyPresence(
        c,
        neighbors: [a, b],
        canRelay: true,
        capacityBytesPerSecond: 1000,
        at: now.add(const Duration(days: 365)),
      );

      expect(topology.infoFor(c)?.updatedAt, now);
      expect(topology.candidates(source: a, destination: b), hasLength(1));

      clock.advance(const Duration(minutes: 2));
      expect(topology.candidates(source: a, destination: b), isEmpty);
    });

    test('R-11: disableRelay держится до более нового presence', () {
      final clock = FakeClock(DateTime.utc(2026));
      final topology = RelayTopology(clock: clock.call);
      final a = peer(1);
      final b = peer(2);
      final c = peer(3);
      final now = clock();

      topology.applyPresence(
        c,
        neighbors: [a, b],
        canRelay: true,
        capacityBytesPerSecond: 1000,
        at: now.subtract(const Duration(seconds: 10)),
      );
      topology.disableRelay(c);
      topology.applyPresence(
        c,
        neighbors: [a, b],
        canRelay: true,
        capacityBytesPerSecond: 1000,
        at: now.subtract(const Duration(seconds: 20)),
      );

      expect(topology.infoFor(c)?.canRelay, isFalse);

      topology.applyPresence(
        c,
        neighbors: [a, b],
        canRelay: true,
        capacityBytesPerSecond: 1000,
        at: now,
      );

      expect(topology.infoFor(c)?.canRelay, isTrue);
    });

    test('R-11: announce соблюдает монотонность и границу будущего', () {
      final clock = FakeClock(DateTime.utc(2026));
      final topology = RelayTopology(clock: clock.call);
      final a = peer(1);
      final b = peer(2);
      final c = peer(3);
      final now = clock();

      topology.announce(
        RelayPeer(
          peerId: c,
          neighbors: {a, b},
          updatedAt: now.subtract(const Duration(seconds: 10)),
          canRelay: true,
          capacityBytesPerSecond: 1000,
        ),
      );
      topology.announce(
        RelayPeer(
          peerId: c,
          neighbors: {b},
          updatedAt: now.subtract(const Duration(seconds: 20)),
          canRelay: false,
        ),
      );

      expect(topology.infoFor(c)?.neighbors, {a, b});
      expect(topology.infoFor(c)?.canRelay, isTrue);

      topology.announce(
        RelayPeer(
          peerId: c,
          neighbors: {a},
          updatedAt: now.add(const Duration(days: 365)),
          canRelay: false,
        ),
      );

      expect(topology.infoFor(c)?.updatedAt, now);
      expect(topology.infoFor(c)?.neighbors, {a});
      expect(topology.infoFor(c)?.canRelay, isFalse);
    });

    test('R-11: announce не разделяет neighbors с вызывающим', () {
      final topology = RelayTopology();
      final a = peer(1);
      final b = peer(2);
      final c = peer(3);
      final neighbors = <PeerId>{a, b};

      topology.announce(
        RelayPeer(
          peerId: c,
          neighbors: neighbors,
          updatedAt: DateTime.utc(2026),
          canRelay: true,
          capacityBytesPerSecond: 1000,
        ),
      );

      neighbors
        ..clear()
        ..add(peer(9));

      expect(topology.infoFor(c)?.neighbors, {a, b});
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

    test('A→B через C: релей не меняет payload, а только заголовок', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);

      announce(topology, c.id, neighbors: [a.id, b.id]);
      a.direct.reachable.add(c.id);
      c.direct.reachable.add(b.id);

      final payload = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef, 7, 8, 9]);

      final received = b.relay.incoming.first;
      final result = await a.relay.deliver(b.id, payload);

      expect(result, isA<RelayedSent>());
      expect((result as RelayedSent).relay, c.id);

      await pump([a, b, c]);

      final forwarded = decodeFrame(c.direct.sent.single.bytes);
      expect(forwarded, isNotNull);
      expect(forwarded!.payload, payload);
      expect(forwarded.src, a.id.publicKey);
      expect(forwarded.dst, b.id.publicKey);
      expect(forwarded.hopCount, 1);
      expect(forwarded.ttl, a.config.maxHops - 1);

      final inbound = await received;
      expect(inbound.src, a.id);
      expect(inbound.payload, payload);
    });

    test('пропажа релея: пересчёт на запасной путь, затем noRoute', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);
      final d = SimNode(id: peer(4), topology: topology);

      announce(
        topology,
        c.id,
        neighbors: [a.id, b.id],
        rtt: const Duration(milliseconds: 10),
      );
      announce(
        topology,
        d.id,
        neighbors: [a.id, b.id],
        rtt: const Duration(milliseconds: 80),
      );
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
    test(
      'R-01: первый хоп требует from == src и ключует лимит по from',
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
      },
    );

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
      expect(metrics.forwardedBytesBySource.containsKey(peer(1)), isFalse);

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
        await c.relay.accept(origin.id, await signedEnvelope(origin, frame));
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

      await c.relay.accept(a.id, Uint8List(a.config.maxFrameBytes + 1));
      expect(c.relay.metrics.droppedOversize, 1);
    });

    test(
      'R-04: token bucket по from применяется и к локальной доставке',
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

        expect(b.relay.metrics.delivered, 0);
        expect(b.relay.metrics.queuedInbound, 1);
        expect(b.relay.metrics.droppedRateLimited, 1);
      },
    );

    test(
      'R-05: unknown-поля списываются и отбрасываются при пересылке',
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
      },
    );

    test('R-06: seen фиксируется после успеха, пустой кэш не падает', () async {
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
      expect(emptyCache.relay.metrics.queuedInbound, 2);
      expect(emptyCache.relay.metrics.delivered, 0);
    });

    test('R-07: MemberRelay пробрасывает ошибку доставки', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology, config: relayConfig());
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

      final tamperedTtl = RelayEnvelope.encode(signedFrame.copyWith(ttl: 1));
      await c.relay.accept(a.id, tamperedTtl);
      expect(c.relay.metrics.droppedBadSignature, 4);

      final wrongOrigin = await signedEnvelope(b, base);
      await c.relay.accept(a.id, wrongOrigin);
      expect(c.relay.metrics.droppedBadSignature, 5);

      expect(c.direct.sent, isEmpty);
    });

    test(
      'nonce различает одинаковый payload, replay по nonce отсекается',
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
      },
    );

    test('реальный Ed25519 signer проходит A→C→B через relay-канал', () async {
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
      expect(
        config.perSourceBurstBytes,
        greaterThanOrEqualTo(config.maxFrameBytes),
      );

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

  group('R-10: failover без удаления presence', () {
    test('accept при сбое прямого адресата пробует релея', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(
        id: peer(3),
        topology: topology,
        config: const RelayConfig(
          relayEnabled: true,
          forwardTimeout: Duration(milliseconds: 5),
        ),
      );
      final d = SimNode(id: peer(4), topology: topology);

      announce(topology, b.id, neighbors: [c.id], canRelay: false);
      announce(topology, d.id, neighbors: [c.id, b.id]);
      c.direct.blackhole.add(b.id);
      c.direct.reachable.add(d.id);

      final frame = RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(20),
        payload: Uint8List.fromList([1, 2, 3]),
      );
      await c.relay.accept(a.id, await signedEnvelope(a, frame));

      expect(c.relay.metrics.forwardFailed, 1);
      expect(c.direct.sent.single.dst, d.id);
      expect(topology.infoFor(b.id), isNotNull);
      expect(topology.linked(c.id, b.id), isTrue);
      expect(topology.infoFor(d.id)?.canRelay, isTrue);
    });

    test('accept снимает только relay-роль упавшего релея', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(
        id: peer(3),
        topology: topology,
        config: const RelayConfig(
          relayEnabled: true,
          forwardTimeout: Duration(milliseconds: 5),
        ),
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
        nonce: frameNonce(21),
        payload: Uint8List.fromList([4, 5, 6]),
      );
      await c.relay.accept(a.id, await signedEnvelope(a, frame));

      expect(c.direct.sent.single.dst, e.id);
      expect(topology.infoFor(d.id), isNotNull);
      expect(topology.infoFor(d.id)?.canRelay, isFalse);
      expect(topology.infoFor(d.id)?.neighbors, containsAll([c.id, b.id]));
      expect(topology.infoFor(e.id)?.canRelay, isTrue);

      await c.relay.accept(
        a.id,
        await signedEnvelope(
          a,
          frame.copyWith(
            nonce: frameNonce(22),
            payload: Uint8List.fromList([7]),
          ),
        ),
      );
      expect(c.direct.sent.last.dst, e.id);
      expect(c.relay.metrics.forwardFailed, 1);
    });

    test(
      'accept считает forwardExhausted при исчерпании альтернатив',
      () async {
        final topology = RelayTopology();
        final a = SimNode(id: peer(1), topology: topology);
        final b = SimNode(id: peer(2), topology: topology);
        final c = SimNode(
          id: peer(3),
          topology: topology,
          config: const RelayConfig(
            relayEnabled: true,
            forwardTimeout: Duration(milliseconds: 5),
          ),
        );
        final d = SimNode(id: peer(4), topology: topology);

        announce(topology, d.id, neighbors: [c.id, b.id]);
        c.direct.blackhole.add(d.id);

        final frame = RelayFrame(
          dst: b.id.publicKey,
          src: a.id.publicKey,
          ttl: 2,
          hopCount: 0,
          nonce: frameNonce(23),
          payload: Uint8List.fromList([1]),
        );
        await c.relay.accept(a.id, await signedEnvelope(a, frame));

        expect(c.direct.sent, isEmpty);
        expect(c.relay.metrics.forwardFailed, 1);
        expect(c.relay.metrics.forwardExhausted, 1);
        expect(topology.infoFor(d.id), isNotNull);
        expect(topology.infoFor(d.id)?.canRelay, isFalse);
      },
    );

    test('deliver снимает relay-роль и сохраняет presence релея', () async {
      final topology = RelayTopology();
      final a = SimNode(
        id: peer(1),
        topology: topology,
        config: const RelayConfig(
          relayEnabled: true,
          directTimeout: Duration(milliseconds: 5),
          forwardTimeout: Duration(milliseconds: 5),
        ),
      );
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);
      final d = SimNode(id: peer(4), topology: topology);

      announce(
        topology,
        c.id,
        neighbors: [a.id, b.id],
        rtt: const Duration(milliseconds: 5),
      );
      announce(
        topology,
        d.id,
        neighbors: [a.id, b.id],
        rtt: const Duration(milliseconds: 50),
      );
      a.direct.blackhole.add(c.id);
      a.direct.reachable.add(d.id);
      d.direct.reachable.add(b.id);

      final result = await a.relay.deliver(b.id, [8, 9]);

      expect(result, isA<RelayedSent>());
      expect((result as RelayedSent).relay, d.id);
      expect(a.direct.sent.single.dst, d.id);
      expect(topology.infoFor(c.id), isNotNull);
      expect(topology.infoFor(c.id)?.canRelay, isFalse);
      expect(topology.infoFor(d.id)?.canRelay, isTrue);
    });
  });

  group('R-12…R-15: потоки, закрытие и границы', () {
    test('R-12: кадры до подписки буферизуются', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final frame = RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(30),
        payload: Uint8List.fromList([1, 2, 3]),
      );

      await b.relay.accept(a.id, await signedEnvelope(a, frame));

      expect(b.relay.metrics.queuedInbound, 1);
      expect(b.relay.metrics.delivered, 0);
      final inbound = await b.relay.incoming.first.timeout(
        const Duration(seconds: 1),
      );
      expect(inbound.src, a.id);
      expect(inbound.payload, [1, 2, 3]);
      expect(b.relay.metrics.delivered, 1);
    });

    test('R-12: буфер ограничен, переполнение считается', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(
        id: peer(2),
        topology: topology,
        config: relayConfig(incomingBufferFrames: 1),
      );

      RelayFrame frame(int nonce, int payload) => RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(nonce),
        payload: Uint8List.fromList([payload]),
      );

      await b.relay.accept(a.id, await signedEnvelope(a, frame(31, 1)));
      await b.relay.accept(a.id, await signedEnvelope(a, frame(32, 2)));

      expect(b.relay.metrics.queuedInbound, 1);
      expect(b.relay.metrics.droppedInboundOverflow, 1);
      final inbound = await b.relay.incoming.first.timeout(
        const Duration(seconds: 1),
      );
      expect(inbound.payload, [1]);
      expect(b.relay.metrics.delivered, 1);
    });

    test('R-12: close закрывает direct и оба потока', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final eventsDone = expectLater(a.relay.events, emitsDone);
      final incomingDone = expectLater(a.relay.incoming, emitsDone);

      await a.relay.close();
      await eventsDone;
      await incomingDone;

      expect(a.direct.closed, isTrue);
      final failed = await a.relay.deliver(peer(2), [1]);
      expect(failed, isA<RelaySendFailed>());
      expect((failed as RelaySendFailed).reason, RelayFailureReason.closed);
      await a.relay.accept(peer(2), [1]);
    });

    test('R-12: завершение direct не синтезирует closed', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final types = <String>[];
      a.relay.events.listen((event) => types.add(event.type));
      final done = expectLater(a.relay.events, emitsDone);

      a.direct.finishEvents();
      await done;

      expect(types, isNot(contains('closed')));
      final failed = await a.relay.deliver(peer(2), [1]);
      expect(failed, isA<RelaySendFailed>());
      expect((failed as RelaySendFailed).reason, RelayFailureReason.closed);
    });

    test('R-14: после seenTtl повтор снова принимается', () async {
      final clock = FakeClock(DateTime.utc(2026));
      final monotonic = FakeMonotonic();
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(
        id: peer(3),
        topology: topology,
        clock: clock.call,
        monotonicClock: monotonic.call,
        config: relayConfig(seenTtl: const Duration(seconds: 5)),
      );

      announce(topology, c.id, neighbors: [a.id, b.id]);
      c.direct.reachable.add(b.id);

      final bytes = await signedEnvelope(
        a,
        RelayFrame(
          dst: b.id.publicKey,
          src: a.id.publicKey,
          ttl: 2,
          hopCount: 0,
          nonce: frameNonce(33),
          payload: Uint8List.fromList([1]),
        ),
      );

      await c.relay.accept(a.id, bytes);
      await c.relay.accept(a.id, bytes);
      expect(c.relay.metrics.forwarded, 1);
      expect(c.relay.metrics.droppedDuplicate, 1);

      clock.advance(const Duration(seconds: 6));
      monotonic.advance(const Duration(seconds: 6));
      await c.relay.accept(a.id, bytes);
      expect(c.relay.metrics.forwarded, 2);
    });

    test('R-15: malformed и неверные длины полей отбрасываются', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(id: peer(3), topology: topology);
      announce(topology, c.id, neighbors: [a.id, b.id]);
      c.direct.reachable.add(b.id);

      final valid = RelayEnvelope.decode(
        await signedEnvelope(
          a,
          RelayFrame(
            dst: b.id.publicKey,
            src: a.id.publicKey,
            ttl: 2,
            hopCount: 0,
            nonce: frameNonce(34),
            payload: Uint8List.fromList([1]),
          ),
        ),
      )!;
      final cases = <Uint8List>[
        Uint8List(0),
        Uint8List.fromList(RelayEnvelope.magic),
        RelayEnvelope.encode(valid.copyWith(nonce: Uint8List(15))),
        RelayEnvelope.encode(valid.copyWith(src: Uint8List(31))),
        RelayEnvelope.encode(valid.copyWith(dst: Uint8List(31))),
        RelayEnvelope.encode(valid.copyWith(signature: Uint8List(63))),
      ];

      for (final bytes in cases) {
        await c.relay.accept(a.id, bytes);
      }

      expect(c.relay.metrics.droppedMalformed, cases.length);
      expect(c.direct.sent, isEmpty);
    });

    test('R-15: burst — ровно до лимита, затем отказ', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final frame = RelayFrame(
        dst: b.id.publicKey,
        src: a.id.publicKey,
        ttl: 2,
        hopCount: 0,
        nonce: frameNonce(35),
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final bytes = await signedEnvelope(a, frame);
      final c = SimNode(
        id: peer(3),
        topology: topology,
        config: relayConfig(
          perSourceBurstBytes: bytes.length,
          perSourceBytesPerSecond: 1,
        ),
      );
      announce(topology, c.id, neighbors: [a.id, b.id]);
      c.direct.reachable.add(b.id);

      await c.relay.accept(a.id, bytes);
      await c.relay.accept(
        a.id,
        await signedEnvelope(a, frame.copyWith(nonce: frameNonce(36))),
      );

      expect(c.relay.metrics.forwarded, 1);
      expect(c.relay.metrics.droppedRateLimited, 1);
      expect(c.direct.sent, hasLength(1));
    });

    test('R-15: opt-out узел доставляет локально, но не пересылает', () async {
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

      final received = c.relay.incoming.first;
      await c.relay.accept(
        a.id,
        await signedEnvelope(
          a,
          RelayFrame(
            dst: c.id.publicKey,
            src: a.id.publicKey,
            ttl: 2,
            hopCount: 0,
            nonce: frameNonce(37),
            payload: Uint8List.fromList([4]),
          ),
        ),
      );
      expect((await received).payload, [4]);
      expect(c.relay.metrics.delivered, 1);

      await c.relay.accept(
        a.id,
        await signedEnvelope(
          a,
          RelayFrame(
            dst: b.id.publicKey,
            src: a.id.publicKey,
            ttl: 2,
            hopCount: 0,
            nonce: frameNonce(38),
            payload: Uint8List.fromList([5]),
          ),
        ),
      );

      expect(c.relay.metrics.droppedDisabled, 1);
      expect(c.direct.sent, isEmpty);
    });

    test(
      'R-15: сбой пересылки не фиксирует seen, успех дедуплицируется',
      () async {
        final topology = RelayTopology();
        final a = SimNode(id: peer(1), topology: topology);
        final b = SimNode(id: peer(2), topology: topology);
        final c = SimNode(
          id: peer(3),
          topology: topology,
          config: relayConfig(forwardTimeout: const Duration(milliseconds: 5)),
        );
        final d = SimNode(id: peer(4), topology: topology);
        final e = SimNode(id: peer(5), topology: topology);

        announce(topology, d.id, neighbors: [c.id, b.id]);
        c.direct.blackhole.add(d.id);

        final bytes = await signedEnvelope(
          a,
          RelayFrame(
            dst: b.id.publicKey,
            src: a.id.publicKey,
            ttl: 2,
            hopCount: 0,
            nonce: frameNonce(39),
            payload: Uint8List.fromList([6]),
          ),
        );

        await c.relay.accept(a.id, bytes);
        expect(c.relay.metrics.forwardFailed, 1);
        expect(c.relay.metrics.forwarded, 0);
        expect(c.direct.sent, isEmpty);

        announce(topology, e.id, neighbors: [c.id, b.id]);
        c.direct.reachable.add(e.id);
        await c.relay.accept(a.id, bytes);
        expect(c.relay.metrics.forwarded, 1);
        await c.relay.accept(a.id, bytes);
        expect(c.relay.metrics.droppedDuplicate, 1);
        expect(c.direct.sent, hasLength(1));
      },
    );
  });

  group('R-16…R-27: буфер, shutdown, replay и fingerprint', () {
    RelayFrame localFrame(SimNode src, SimNode dst, int nonce, int payload) =>
        RelayFrame(
          dst: dst.id.publicKey,
          src: src.id.publicKey,
          ttl: 2,
          hopCount: 0,
          nonce: frameNonce(nonce),
          payload: Uint8List.fromList([payload]),
        );

    test('R-16: .first не теряет остальные буферизованные кадры', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(
        id: peer(2),
        topology: topology,
        config: relayConfig(incomingBufferFrames: 4),
      );

      for (var i = 1; i <= 3; i++) {
        await b.relay.accept(
          a.id,
          await signedEnvelope(a, localFrame(a, b, 40 + i, i)),
        );
      }
      expect(b.relay.metrics.queuedInbound, 3);

      for (var i = 1; i <= 3; i++) {
        final inbound = await b.relay.incoming.first.timeout(
          const Duration(seconds: 1),
        );
        expect(inbound.payload, [i]);
      }
      expect(b.relay.metrics.delivered, 3);
    });

    test('R-16: несколько кадров сохраняют порядок', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(
        id: peer(2),
        topology: topology,
        config: relayConfig(incomingBufferFrames: 4),
      );

      for (var i = 1; i <= 3; i++) {
        await b.relay.accept(
          a.id,
          await signedEnvelope(a, localFrame(a, b, 50 + i, i)),
        );
      }

      final received = await b.relay.incoming
          .take(3)
          .map((inbound) => inbound.payload.single)
          .toList()
          .timeout(const Duration(seconds: 1));
      expect(received, [1, 2, 3]);
    });

    test('R-25: после отмены слушателя буфер снова активен', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(
        id: peer(2),
        topology: topology,
        config: relayConfig(incomingBufferFrames: 4),
      );

      final subscription = b.relay.incoming.listen((_) {});
      await subscription.cancel();

      await b.relay.accept(
        a.id,
        await signedEnvelope(a, localFrame(a, b, 60, 1)),
      );
      await b.relay.accept(
        a.id,
        await signedEnvelope(a, localFrame(a, b, 61, 2)),
      );
      expect(b.relay.metrics.queuedInbound, 2);

      final received = await b.relay.incoming
          .take(2)
          .map((inbound) => inbound.payload.single)
          .toList()
          .timeout(const Duration(seconds: 1));
      expect(received, [1, 2]);
    });

    test('R-20/R-21: overflow не фиксирует seen и не считается без буфера', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(
        id: peer(2),
        topology: topology,
        config: relayConfig(incomingBufferFrames: 1),
      );

      await b.relay.accept(
        a.id,
        await signedEnvelope(a, localFrame(a, b, 70, 1)),
      );
      await b.relay.accept(
        a.id,
        await signedEnvelope(a, localFrame(a, b, 71, 2)),
      );
      expect(b.relay.metrics.queuedInbound, 1);
      expect(b.relay.metrics.droppedInboundOverflow, 1);

      final first = await b.relay.incoming.first.timeout(
        const Duration(seconds: 1),
      );
      expect(first.payload, [1]);

      // Отброшенный при переполнении кадр не попал в seen и принимается снова.
      await b.relay.accept(
        a.id,
        await signedEnvelope(a, localFrame(a, b, 71, 2)),
      );
      final second = await b.relay.incoming.first.timeout(
        const Duration(seconds: 1),
      );
      expect(second.payload, [2]);
      expect(b.relay.metrics.droppedDuplicate, 0);

      final disabled = SimNode(
        id: peer(3),
        topology: topology,
        config: relayConfig(incomingBufferFrames: 0),
      );
      await disabled.relay.accept(
        a.id,
        await signedEnvelope(a, localFrame(a, disabled, 72, 3)),
      );
      expect(disabled.relay.metrics.droppedInboundNoBuffer, 1);
      expect(disabled.relay.metrics.droppedInboundOverflow, 0);
      expect(disabled.relay.metrics.queuedInbound, 0);

      final live = disabled.relay.incoming.first.timeout(
        const Duration(seconds: 1),
      );
      await disabled.relay.accept(
        a.id,
        await signedEnvelope(a, localFrame(a, disabled, 73, 4)),
      );
      expect((await live).payload, [4]);
      expect(disabled.relay.metrics.delivered, 1);
    });

    test('R-20: close учитывает неотданные буферизованные кадры', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(
        id: peer(2),
        topology: topology,
        config: relayConfig(incomingBufferFrames: 4),
      );

      await b.relay.accept(
        a.id,
        await signedEnvelope(a, localFrame(a, b, 80, 1)),
      );
      await b.relay.accept(
        a.id,
        await signedEnvelope(a, localFrame(a, b, 81, 2)),
      );
      await b.relay.close();

      expect(b.relay.metrics.queuedInbound, 2);
      expect(b.relay.metrics.delivered, 0);
      expect(b.relay.metrics.droppedInboundClosed, 2);
    });

    test('R-17: close во время in-flight accept не меняет метрики', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final b = SimNode(id: peer(2), topology: topology);
      final c = SimNode(
        id: peer(3),
        topology: topology,
        config: relayConfig(forwardTimeout: const Duration(milliseconds: 20)),
      );
      final d = SimNode(id: peer(4), topology: topology);

      announce(topology, d.id, neighbors: [c.id, b.id]);
      c.direct.blackhole.add(d.id);

      final pending = c.relay.accept(
        a.id,
        await signedEnvelope(a, localFrame(a, b, 82, 1)),
      );
      await c.relay.close();
      await pending;

      expect(c.relay.metrics.forwardFailed, 0);
      expect(c.relay.metrics.forwarded, 0);
      expect(c.direct.sent, isEmpty);
      expect(c.direct.closeCount, 1);
    });

    test('R-17: close во время in-flight deliver возвращает closed', () async {
      final topology = RelayTopology();
      final a = SimNode(
        id: peer(1),
        topology: topology,
        config: relayConfig(directTimeout: const Duration(milliseconds: 20)),
      );
      final b = SimNode(id: peer(2), topology: topology);
      a.direct.blackhole.add(b.id);

      final pending = a.relay.deliver(b.id, [1, 2, 3]);
      await a.relay.close();
      final result = await pending;

      expect(result, isA<RelaySendFailed>());
      expect((result as RelaySendFailed).reason, RelayFailureReason.closed);
      expect(a.relay.metrics.directFailed, 0);
      expect(a.relay.metrics.relaySendFailed, 0);
    });

    test('R-18: close идемпотентен и ждёт завершения direct', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);

      await Future.wait([a.relay.close(), a.relay.close()]);
      expect(a.direct.closeCount, 1);
      expect(a.direct.closed, isTrue);
    });

    test(
      'R-18: close после завершения direct всё равно закрывает direct',
      () async {
        final topology = RelayTopology();
        final a = SimNode(id: peer(1), topology: topology);
        final done = expectLater(a.relay.events, emitsDone);

        a.direct.finishEvents();
        await done;
        expect(a.direct.closed, isFalse);

        await a.relay.close();
        expect(a.direct.closed, isTrue);
        expect(a.direct.closeCount, 1);
      },
    );

    test('R-26: ошибки direct.events пробрасываются в relay.events', () async {
      final topology = RelayTopology();
      final a = SimNode(id: peer(1), topology: topology);
      final error = StateError('direct boom');
      final received = expectLater(a.relay.events, emitsError(error));

      a.direct.failEvents(error);
      await received;
      await a.relay.close();
    });

    test(
      'R-22/R-23: полный seen не вытесняет nonce, TTL идёт по монотонным',
      () async {
        final clock = FakeClock(DateTime.utc(2026));
        final monotonic = FakeMonotonic();
        final topology = RelayTopology();
        final a = SimNode(id: peer(1), topology: topology);
        final b = SimNode(id: peer(2), topology: topology);
        final c = SimNode(
          id: peer(3),
          topology: topology,
          clock: clock.call,
          monotonicClock: monotonic.call,
          config: relayConfig(seenMaxEntries: 1),
        );
        announce(topology, c.id, neighbors: [a.id, b.id]);
        c.direct.reachable.add(b.id);

        final first = await signedEnvelope(a, localFrame(a, b, 90, 1));
        final second = await signedEnvelope(a, localFrame(a, b, 91, 2));

        await c.relay.accept(a.id, first);
        expect(c.relay.metrics.forwarded, 1);

        clock.advance(const Duration(hours: 1));
        await c.relay.accept(a.id, second);
        expect(c.relay.metrics.forwarded, 1);
        expect(c.relay.metrics.droppedSeenFull, 1);

        monotonic.advance(const Duration(minutes: 6));
        await c.relay.accept(a.id, second);
        expect(c.relay.metrics.forwarded, 2);
      },
    );

    test(
      'R-27: реальный Ed25519 отвергает tamper, чужой src и replay',
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
        c.direct.reachable.add(b.id);

        final frame = RelayFrame(
          dst: b.id.publicKey,
          src: a.id.publicKey,
          ttl: 2,
          hopCount: 0,
          nonce: frameNonce(92),
          payload: Uint8List.fromList([9]),
        );
        final envelope = await signedEnvelope(a, frame);
        final decoded = RelayEnvelope.decode(envelope)!;

        final tampered = RelayEnvelope.encode(
          decoded.copyWith(payload: Uint8List.fromList([8])),
        );
        await c.relay.accept(a.id, tampered);
        expect(c.relay.metrics.droppedBadSignature, 1);
        expect(c.direct.sent, isEmpty);

        final foreignSrc = RelayEnvelope.encode(
          decoded.copyWith(src: bob.peerId.publicKey),
        );
        await c.relay.accept(bob.peerId, foreignSrc);
        expect(c.relay.metrics.droppedBadSignature, 2);
        expect(c.direct.sent, isEmpty);

        await c.relay.accept(a.id, envelope);
        expect(c.relay.metrics.forwarded, 1);
        await c.relay.accept(a.id, envelope);
        expect(c.relay.metrics.droppedDuplicate, 1);
        expect(c.direct.sent, hasLength(1));
      },
    );
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
