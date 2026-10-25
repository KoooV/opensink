import 'dart:async';
import 'dart:typed_data';

import 'package:app/di/providers.dart';
import 'package:app/di/sync_links.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart' hide RelayFrame;
import 'package:core_protocol/core_protocol.dart' show RelayFrame;
import 'package:core_relay/core_relay.dart';
import 'package:core_sync/core_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _DirectTransport implements Transport {
  final StreamController<PeerLinkEvent> _events =
      StreamController<PeerLinkEvent>.broadcast();
  final StreamController<RelayDatagram> _relayIncoming =
      StreamController<RelayDatagram>.broadcast();
  final List<(PeerId, List<int>)> sent = <(PeerId, List<int>)>[];
  final List<PeerId> relaySent = <PeerId>[];
  final List<PeerId> connected = <PeerId>[];
  final Map<PeerId, FakePeerLink> links = <PeerId, FakePeerLink>{};
  bool failDirectSend = false;
  bool closed = false;

  @override
  Stream<PeerLinkEvent> get events => _events.stream;

  @override
  Stream<RelayDatagram> get relayIncoming => _relayIncoming.stream;

  @override
  PeerLinkStats? statsFor(PeerId peerId) => null;

  @override
  Future<PeerLink> connect(PeerId peerId) async {
    connected.add(peerId);
    return links.putIfAbsent(peerId, () => FakePeerLink(peerId));
  }

  @override
  Future<void> send(PeerId dst, List<int> bytes) async {
    if (failDirectSend) {
      throw StateError('direct link is down');
    }
    sent.add((dst, List<int>.from(bytes)));
  }

  @override
  Future<void> sendRelay(PeerId dst, List<int> bytes) async {
    relaySent.add(dst);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _events.close();
    await _relayIncoming.close();
  }

  void emitEvent(String type, PeerId peerId) {
    _events.add(PeerLinkEvent(type, peerId));
  }
}

class _PacketAttacher {
  final Map<String, SyncLink> links = <String, SyncLink>{};
  final List<String> detached = <String>[];

  Future<void> attach(SyncLink link) async {
    links[link.peerId] = link;
  }

  Future<void> detach(String peerId) async {
    detached.add(peerId);
    final link = links.remove(peerId);
    await link?.close();
  }
}

PeerId _peer(int value) {
  final bytes = Uint8List(32);
  bytes[0] = value;
  return PeerId(bytes);
}

void main() {
  const groupA = GroupId('sync-links-a');
  const groupB = GroupId('sync-links-b');

  late _DirectTransport direct;
  late RelayTransport relay;
  late PeerId local;
  late RelayTopology topology;
  late CryptoSigner localSigner;
  RelayTransport? relayForClose;

  Future<void> setUpRelay() async {
    final identity = await generateIdentity();
    local = PeerId(Uint8List.fromList(hexToBytes(identity.userId.value)));
    localSigner = CryptoSigner(identity.ed25519PrivateKey);
    direct = _DirectTransport();
    topology = RelayTopology();
    relay = RelayTransport(
      localPeerId: local,
      direct: direct,
      topology: topology,
      signer: localSigner,
      config: const RelayConfig(),
      initialLocalNeighbors: const <PeerId>[],
    );
    relayForClose = relay;
  }

  tearDown(() async {
    await relayForClose?.close();
    relayForClose = null;
  });

  test('RelayPacketTransport отправляет через relay fallback', () async {
    await setUpRelay();
    final adapter = RelayPacketTransport(relay: relay);
    final destination = _peer(20);
    final relayPeer = _peer(10);
    direct.failDirectSend = true;
    topology.announce(
      RelayPeer(
        peerId: relayPeer,
        neighbors: <PeerId>{local, destination},
        updatedAt: DateTime.now(),
        canRelay: true,
        capacityBytesPerSecond: 100000,
      ),
    );

    await adapter.send(
      hexEncode(destination.publicKey),
      Uint8List.fromList(<int>[5, 6]),
    );

    expect(direct.relaySent, <PeerId>[relayPeer]);
  });

  test(
    'RelayPacketTransport маппит входящий RelayInbound в SyncPacket',
    () async {
      await setUpRelay();
      final remote = await generateIdentity();
      final remotePeer = PeerId(
        Uint8List.fromList(hexToBytes(remote.userId.value)),
      );
      final remoteSigner = CryptoSigner(remote.ed25519PrivateKey);
      final adapter = RelayPacketTransport(relay: relay);
      final received = adapter.incoming.first;

      final frame = RelayFrame(
        dst: local.publicKey,
        src: remotePeer.publicKey,
        ttl: 1,
        hopCount: 0,
        payload: Uint8List.fromList(<int>[9, 8, 7]),
        nonce: Uint8List.fromList(List<int>.generate(16, (index) => index)),
      );
      final signature = await RelayFrameAuth.sign(frame, remoteSigner);
      await relay.accept(
        remotePeer,
        RelayEnvelope.encode(frame.copyWith(signature: signature)),
      );

      final packet = await received;
      expect(packet.src, hexEncode(remotePeer.publicKey));
      expect(packet.payload, <int>[9, 8, 7]);
    },
  );

  test('коннектор сеет relay-линки из топологии', () async {
    await setUpRelay();
    final attacher = _PacketAttacher();
    final remote = _peer(21);
    topology.announce(
      RelayPeer(
        peerId: remote,
        neighbors: <PeerId>{local},
        updatedAt: DateTime.now(),
      ),
    );
    final connector = SyncLinkConnector(
      transport: relay,
      attach: attacher.attach,
      detach: attacher.detach,
    );
    addTearDown(connector.close);

    await connector.start();

    expect(connector.modeOf(remote), SyncLinkMode.relay);
    expect(attacher.links[hexEncode(remote.publicKey)], isA<PacketSyncLink>());
  });

  test('коннектор переключает direct ↔ relay по событиям', () async {
    await setUpRelay();
    final attacher = _PacketAttacher();
    final remote = _peer(22);
    final connector = SyncLinkConnector(
      transport: relay,
      attach: attacher.attach,
      detach: attacher.detach,
    );
    addTearDown(connector.close);

    await connector.start();
    direct.emitEvent('connected', remote);
    await Future<void>.delayed(Duration.zero);

    expect(connector.modeOf(remote), SyncLinkMode.direct);
    expect(
      attacher.links[hexEncode(remote.publicKey)],
      isA<PeerLinkSyncLink>(),
    );
    expect(direct.connected, contains(remote));

    direct.emitEvent('disconnected', remote);
    await Future<void>.delayed(Duration.zero);

    expect(connector.modeOf(remote), SyncLinkMode.relay);
    expect(attacher.links[hexEncode(remote.publicKey)], isA<PacketSyncLink>());
    expect(attacher.detached, contains(hexEncode(remote.publicKey)));
  });

  test('close коннектора отцепляет линки и не закрывает транспорт', () async {
    await setUpRelay();
    final attacher = _PacketAttacher();
    final remote = _peer(23);
    topology.announce(
      RelayPeer(
        peerId: remote,
        neighbors: <PeerId>{local},
        updatedAt: DateTime.now(),
      ),
    );
    final connector = SyncLinkConnector(
      transport: relay,
      attach: attacher.attach,
      detach: attacher.detach,
    );

    await connector.start();
    await connector.close();

    expect(attacher.links, isEmpty);
    expect(direct.closed, isFalse);
    expect(connector.modeOf(remote), isNull);
    await relay.send(remote, <int>[1]);
    expect(direct.sent, hasLength(1));
  });

  test(
    'activeTransportProvider отдаёт RelayTransport и следует за группой',
    () async {
      final firstIdentity = await generateIdentity();
      final secondIdentity = await generateIdentity();
      final firstDirect = _DirectTransport();
      final secondDirect = _DirectTransport();
      addTearDown(firstDirect.close);
      addTearDown(secondDirect.close);
      final first = RelayTransport(
        localPeerId: PeerId(
          Uint8List.fromList(hexToBytes(firstIdentity.userId.value)),
        ),
        direct: firstDirect,
        topology: RelayTopology(),
        signer: CryptoSigner(firstIdentity.ed25519PrivateKey),
        config: const RelayConfig(),
      );
      final second = RelayTransport(
        localPeerId: PeerId(
          Uint8List.fromList(hexToBytes(secondIdentity.userId.value)),
        ),
        direct: secondDirect,
        topology: RelayTopology(),
        signer: CryptoSigner(secondIdentity.ed25519PrivateKey),
        config: const RelayConfig(),
      );
      addTearDown(first.close);
      addTearDown(second.close);
      final controller = _MutableActiveGroupController(groupA);
      final container = ProviderContainer(
        overrides: <Override>[
          activeGroupIdProvider.overrideWith(() => controller),
          relayTransportProvider(groupA).overrideWith((ref) async => first),
          relayTransportProvider(groupB).overrideWith((ref) async => second),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        activeTransportProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      expect(await container.read(activeTransportProvider.future), same(first));

      controller.set(groupB);

      expect(
        await container.read(activeTransportProvider.future),
        same(second),
      );
    },
  );
}

class _MutableActiveGroupController extends ActiveGroupController {
  _MutableActiveGroupController(this._value);

  GroupId? _value;

  @override
  Future<GroupId?> build() async => _value;

  void set(GroupId? value) {
    _value = value;
    state = AsyncData(value);
  }
}
