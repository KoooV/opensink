import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide RelayFrame;
import 'package:core_domain/core_domain.dart' as domain show RelayFrame;
import 'package:core_protocol/core_protocol.dart' show RelayFrame;
import 'package:core_relay/core_relay.dart';
import 'package:test/test.dart';

PeerId peer(int value) {
  final bytes = Uint8List(32);
  bytes[0] = value;
  return PeerId(bytes);
}

class FakeClock {
  FakeClock(this._now);

  DateTime _now;

  DateTime call() => _now;

  void advance(Duration duration) => _now = _now.add(duration);
}

class Sent {
  Sent(this.dst, this.bytes);

  final PeerId dst;
  final Uint8List bytes;
}

class ScriptedTransport implements Transport {
  ScriptedTransport(this.localPeerId);

  final PeerId localPeerId;
  final _events = StreamController<PeerLinkEvent>.broadcast();
  final sent = <Sent>[];
  final reachable = <PeerId>{};
  final blackhole = <PeerId>{};

  @override
  Stream<PeerLinkEvent> get events => _events.stream;

  @override
  Future<PeerLink> connect(PeerId peerId) async => FakePeerLink(peerId);

  @override
  Future<void> send(PeerId dst, List<int> bytes) async {
    if (blackhole.contains(dst)) {
      return Completer<void>().future;
    }
    if (!reachable.contains(dst)) {
      throw StateError('unreachable $dst');
    }
    sent.add(Sent(dst, Uint8List.fromList(bytes)));
  }

  @override
  Future<void> close() async {
    await _events.close();
  }
}

class SimNode {
  SimNode({
    required this.id,
    required this.topology,
    this.config = const RelayConfig(),
    DateTime Function()? clock,
  }) {
    direct = ScriptedTransport(id);
    relay = RelayTransport(
      localPeerId: id,
      direct: direct,
      topology: topology,
      config: config,
      clock: clock,
    );
  }

  final PeerId id;
  final RelayTopology topology;
  final RelayConfig config;
  late final ScriptedTransport direct;
  late final RelayTransport relay;
  int read = 0;
}

RelayFrame? decodeFrame(Uint8List bytes) {
  try {
    final frame = RelayFrame.fromBytes(bytes);
    if (frame.dst.length != 32 || frame.src.length != 32) {
      return null;
    }
    return frame;
  } catch (_) {
    return null;
  }
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
        config: const RelayConfig(directTimeout: Duration(milliseconds: 5)),
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
        payload: Uint8List.fromList([payload]),
      );

      await c.relay.accept(a.id, frame(1).toBytes());
      await c.relay.accept(a.id, frame(1).toBytes());

      expect(c.direct.sent, hasLength(1));
      expect(c.relay.metrics.forwarded, 1);
      expect(c.relay.metrics.droppedDuplicate, 1);

      await a.relay.accept(c.id, frame(2).toBytes());
      expect(a.relay.metrics.droppedLoop, 1);

      await c.relay.accept(a.id, frame(3, ttl: 0).toBytes());
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
          perSourceBurstBytes: 100,
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
        payload: Uint8List.fromList(payload),
      );

      await c.relay.accept(a.id, frame(List<int>.filled(10, 1)).toBytes());
      await c.relay.accept(a.id, frame(List<int>.filled(11, 2)).toBytes());

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
        payload: Uint8List.fromList([1, 2, 3]),
      );
      await c.relay.accept(a.id, frame.toBytes());

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
      domain.RelayFrame(dst: b.id, payload: Uint8List.fromList([42])),
    );

    expect(a.direct.sent.single.dst, b.id);
    expect(a.direct.sent.single.bytes, [42]);
  });
}
