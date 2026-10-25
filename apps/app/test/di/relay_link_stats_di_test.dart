import 'dart:async';
import 'dart:typed_data';

import 'package:app/di/providers.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_relay/core_relay.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

PeerId _peer(int value) {
  final bytes = Uint8List(32);
  bytes[0] = value;
  return PeerId(bytes);
}

PeerLinkStats _stats(int milliseconds) => PeerLinkStats(
  rtt: Duration(milliseconds: milliseconds),
  bytesSent: 0,
  bytesReceived: 0,
  loss: 0,
);

class _StatsTransport implements Transport {
  _StatsTransport(this.stats);

  final Map<PeerId, PeerLinkStats> stats;
  final List<PeerId> relayed = <PeerId>[];
  final StreamController<PeerLinkEvent> _events =
      StreamController<PeerLinkEvent>.broadcast();
  final StreamController<RelayDatagram> _relayIncoming =
      StreamController<RelayDatagram>.broadcast();

  @override
  PeerLinkStats? statsFor(PeerId peerId) => stats[peerId];

  @override
  Stream<PeerLinkEvent> get events => _events.stream;

  @override
  Stream<RelayDatagram> get relayIncoming => _relayIncoming.stream;

  @override
  Future<PeerLink> connect(PeerId peerId) async {
    throw StateError('direct connect is not expected');
  }

  @override
  Future<void> send(PeerId dst, List<int> bytes) async {
    throw StateError('direct link is down');
  }

  @override
  Future<void> sendRelay(PeerId dst, List<int> bytes) async {
    relayed.add(dst);
  }

  @override
  Future<void> close() async {
    await _events.close();
    await _relayIncoming.close();
  }
}

void main() {
  const groupId = GroupId('di-relay');

  test('без измерений статистика неизвестна', () async {
    final direct = _StatsTransport(<PeerId, PeerLinkStats>{});
    addTearDown(direct.close);
    final container = ProviderContainer(
      overrides: <Override>[
        transportProvider(groupId).overrideWith((ref) async => direct),
      ],
    );
    addTearDown(container.dispose);

    final lookup = await container.read(relayLinkStatsProvider(groupId).future);

    expect(lookup(_peer(1)), isNull);
  });

  test('relayTransportProvider использует RTT из statsFor', () async {
    final identity = await generateIdentity();
    final local = PeerId(Uint8List.fromList(hexToBytes(identity.userId.value)));
    final relayPeer = _peer(10);
    final destination = _peer(11);
    final measured = _stats(5);
    final direct = _StatsTransport(<PeerId, PeerLinkStats>{
      relayPeer: measured,
    });
    final topology = RelayTopology();
    topology.announce(
      RelayPeer(
        peerId: relayPeer,
        neighbors: <PeerId>{local, destination},
        updatedAt: DateTime.now(),
        canRelay: true,
        capacityBytesPerSecond: 100000,
        rtt: const Duration(milliseconds: 120),
      ),
    );
    final container = ProviderContainer(
      overrides: <Override>[
        transportProvider(groupId).overrideWith((ref) async => direct),
        relayTopologyProvider(groupId).overrideWith((ref) async => topology),
        relayConfigProvider.overrideWithValue(
          const RelayConfig(relayEnabled: true),
        ),
        localIdentityProvider.overrideWith(
          (ref) async => LocalIdentity(
            userId: identity.userId,
            signer: CryptoSigner(identity.ed25519PrivateKey),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final relay = await container.read(relayTransportProvider(groupId).future);

    expect(relay.linkStats, isNotNull);
    expect(relay.linkStats!(relayPeer), measured);
    expect(relay.linkStats!(_peer(99)), isNull);

    final result = await relay.deliver(destination, <int>[1]);

    expect(result, isA<RelayedSent>());
    expect((result as RelayedSent).relay, relayPeer);
    expect(direct.relayed, <PeerId>[relayPeer]);
    expect(topology.infoFor(relayPeer)?.rtt, const Duration(milliseconds: 5));
  });
}
