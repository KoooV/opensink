import 'dart:async';
import 'dart:typed_data';

import 'package:app/e2e/e2e_datagram_transport.dart';
import 'package:app/e2e/e2e_sender_key_channel.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'package:flutter_test/flutter_test.dart';

const _groupId = GroupId('group-e2e');
const _epoch = 3;

class _PairDatagramTransport implements E2eDatagramTransport {
  _PairDatagramTransport(this.localPeerId);

  final PeerId localPeerId;
  final StreamController<E2eDatagram> _incoming =
      StreamController<E2eDatagram>.broadcast();
  late _PairDatagramTransport peer;

  @override
  Stream<E2eDatagram> get incoming => _incoming.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> send(PeerId dst, Uint8List bytes) async {
    if (dst != peer.localPeerId) {
      throw StateError('unexpected destination');
    }
    peer._incoming.add(E2eDatagram(from: localPeerId, bytes: bytes));
  }

  @override
  Future<void> close() async {
    await _incoming.close();
  }
}

class _AllowAllVerifier implements SenderKeyPackageVerifier {
  const _AllowAllVerifier();

  @override
  Future<Result<void, SenderKeyPackageError>> verify(
    SenderKeyPackage package,
  ) async {
    return const Ok(null);
  }
}

class _Node {
  _Node({
    required this.identity,
    required this.bundle,
    required this.store,
    required this.sessions,
    required this.channel,
    required this.transport,
  });

  final CryptoIdentity identity;
  final X3DHKeyBundle bundle;
  final MemoryE2eSessionStore store;
  final E2eSessionManager sessions;
  final E2eSenderKeyChannel channel;
  final _PairDatagramTransport transport;

  UserId get userId => identity.userId;
  PeerId get peerId => PeerId(
    Uint8List.fromList(
      (identity.ed25519PublicKey as crypto_pkg.SimplePublicKey).bytes,
    ),
  );
}

Future<_Node> _node({MemoryE2eSessionStore? store}) async {
  final identity = await generateIdentity();
  final seed = await identity.ed25519PrivateKey.extractBytes();
  final bundle = await X3DH().generateIdentityBoundKeyBundle(
    identitySeed: crypto_pkg.SecretKey(Uint8List.fromList(seed)),
  );
  return _nodeFrom(identity, bundle, store ?? MemoryE2eSessionStore());
}

_Node _nodeFrom(
  CryptoIdentity identity,
  X3DHKeyBundle bundle,
  MemoryE2eSessionStore store,
) {
  final sessions = E2eSessionManager(localBundle: bundle, store: store);
  final transport = _PairDatagramTransport(
    PeerId(
      Uint8List.fromList(
        (identity.ed25519PublicKey as crypto_pkg.SimplePublicKey).bytes,
      ),
    ),
  );
  final channel = E2eSenderKeyChannel(
    localPeerId: transport.localPeerId,
    sessions: sessions,
  );
  return _Node(
    identity: identity,
    bundle: bundle,
    store: store,
    sessions: sessions,
    channel: channel,
    transport: transport,
  );
}

/// Имитирует рестарт: новое in-memory состояние и канал, тот же store/identity.
_Node _restart(_Node previous) =>
    _nodeFrom(previous.identity, previous.bundle, previous.store);

ProductionGroupKeyDistributor _distributor(
  _Node node,
  SenderKeyPackageStore store,
  SenderKeyDelivery delivery,
) {
  return ProductionGroupKeyDistributor(
    localUser: node.userId,
    signer: CryptoSigner(node.identity.ed25519PrivateKey),
    delivery: delivery,
    store: store,
    verifier: const _AllowAllVerifier(),
  );
}

Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'identity-bound сессии и подписанный sender key идут end-to-end',
    () async {
      final alice = await _node();
      final bob = await _node();
      addTearDown(alice.channel.close);
      addTearDown(bob.channel.close);
      addTearDown(alice.transport.close);
      addTearDown(bob.transport.close);
      alice.transport.peer = bob.transport;
      bob.transport.peer = alice.transport;

      await alice.channel.bindTransport(_groupId, alice.transport);
      await bob.channel.bindTransport(_groupId, bob.transport);

      expect(
        (await bob.channel.registerBundle(
          _groupId,
          alice.peerId,
          alice.sessions.publicBundle,
        )).isOk,
        isTrue,
      );
      expect(
        (await alice.channel.registerBundle(
          _groupId,
          bob.peerId,
          bob.sessions.publicBundle,
        )).isOk,
        isTrue,
      );
      await _drain();

      expect(alice.channel.hasSession(bob.peerId), isTrue);
      expect(bob.channel.hasSession(alice.peerId), isTrue);

      final bobStore = MemorySenderKeyPackageStore();
      final bobDistributor = _distributor(
        bob,
        bobStore,
        const UnavailableSenderKeyDelivery(),
      );
      final received = <SenderKeyPackage>[];
      final subscription = bob.channel.received.listen((package) async {
        final result = await bobDistributor.receive(package);
        if (result.isOk) received.add(result.unwrap());
      });
      addTearDown(subscription.cancel);

      final aliceDistributor = _distributor(
        alice,
        MemorySenderKeyPackageStore(),
        E2eSenderKeyDelivery(channel: alice.channel),
      );
      await aliceDistributor.distribute(
        GroupKeyRotation(
          groupId: _groupId,
          epoch: _epoch,
          sender: alice.userId,
          recipients: <UserId>{bob.userId},
          keyPackage: Uint8List.fromList(const <int>[1, 2, 3, 4]),
        ),
      );
      await _drain();

      expect(received, hasLength(1));
      expect(received.single.sender, alice.userId);
      expect(received.single.recipient, bob.userId);
      final verified = (await bobStore.load(
        _groupId,
        SenderKeyPackageState.verified,
      )).unwrap();
      expect(verified, hasLength(1));
      expect(verified.single.package.signature, isNotEmpty);
    },
  );

  test('чужой bundle и отсутствие сессии fail-closed', () async {
    final alice = await _node();
    final bob = await _node();
    final mallory = await _node();
    addTearDown(alice.channel.close);
    addTearDown(bob.channel.close);
    addTearDown(alice.transport.close);
    addTearDown(bob.transport.close);
    addTearDown(mallory.channel.close);
    addTearDown(mallory.transport.close);
    alice.transport.peer = bob.transport;
    bob.transport.peer = alice.transport;
    await alice.channel.bindTransport(_groupId, alice.transport);
    await bob.channel.bindTransport(_groupId, bob.transport);

    final mismatched = await alice.channel.registerBundle(
      _groupId,
      bob.peerId,
      mallory.sessions.publicBundle,
    );
    expect(mismatched.isErr, isTrue);
    expect(alice.channel.hasSession(bob.peerId), isFalse);

    final delivery = await E2eSenderKeyDelivery(channel: alice.channel).deliver(
      SenderKeyPackage(
        groupId: _groupId,
        epoch: _epoch,
        sender: alice.userId,
        recipient: bob.userId,
        keyPackage: Uint8List.fromList(const <int>[5]),
        signature: 'aa' * 64,
      ),
    );
    expect(delivery.isErr, isTrue);
  });

  test('сессия и ratchet восстанавливаются после рестарта', () async {
    final alice = await _node();
    final bob = await _node();
    addTearDown(alice.channel.close);
    addTearDown(bob.channel.close);
    addTearDown(alice.transport.close);
    addTearDown(bob.transport.close);
    alice.transport.peer = bob.transport;
    bob.transport.peer = alice.transport;
    await alice.channel.bindTransport(_groupId, alice.transport);
    await bob.channel.bindTransport(_groupId, bob.transport);

    expect(
      (await bob.channel.registerBundle(
        _groupId,
        alice.peerId,
        alice.sessions.publicBundle,
      )).isOk,
      isTrue,
    );
    expect(
      (await alice.channel.registerBundle(
        _groupId,
        bob.peerId,
        bob.sessions.publicBundle,
      )).isOk,
      isTrue,
    );
    await _drain();
    expect(alice.channel.hasSession(bob.peerId), isTrue);
    expect(bob.channel.hasSession(alice.peerId), isTrue);
    expect(alice.store.length, 1);
    expect(bob.store.length, 1);

    Future<List<SenderKeyPackage>> distribute(
      _Node from,
      _Node to,
      SenderKeyPackageStore toStore,
      int epoch,
    ) async {
      final received = <SenderKeyPackage>[];
      final subscription = to.channel.received.listen((package) async {
        final distributor = _distributor(
          to,
          toStore,
          const UnavailableSenderKeyDelivery(),
        );
        final result = await distributor.receive(package);
        if (result.isOk) received.add(result.unwrap());
      });
      addTearDown(subscription.cancel);
      final sender = _distributor(
        from,
        MemorySenderKeyPackageStore(),
        E2eSenderKeyDelivery(channel: from.channel),
      );
      await sender.distribute(
        GroupKeyRotation(
          groupId: _groupId,
          epoch: epoch,
          sender: from.userId,
          recipients: <UserId>{to.userId},
          keyPackage: Uint8List.fromList(<int>[epoch, 1, 2, 3]),
        ),
      );
      await _drain();
      return received;
    }

    expect(
      await distribute(alice, bob, MemorySenderKeyPackageStore(), _epoch),
      hasLength(1),
    );

    final aliceRestarted = _restart(alice);
    final bobRestarted = _restart(bob);
    addTearDown(aliceRestarted.channel.close);
    addTearDown(bobRestarted.channel.close);
    addTearDown(aliceRestarted.transport.close);
    addTearDown(bobRestarted.transport.close);
    aliceRestarted.transport.peer = bobRestarted.transport;
    bobRestarted.transport.peer = aliceRestarted.transport;
    await aliceRestarted.channel.bindTransport(
      _groupId,
      aliceRestarted.transport,
    );
    await bobRestarted.channel.bindTransport(_groupId, bobRestarted.transport);
    final restoredSessions = <PeerId>[];
    final restoredSubscription = aliceRestarted.channel.established.listen(
      restoredSessions.add,
    );
    addTearDown(restoredSubscription.cancel);

    expect(
      (await bobRestarted.channel.registerBundle(
        _groupId,
        aliceRestarted.peerId,
        aliceRestarted.sessions.publicBundle,
      )).isOk,
      isTrue,
    );
    expect(
      (await aliceRestarted.channel.registerBundle(
        _groupId,
        bobRestarted.peerId,
        bobRestarted.sessions.publicBundle,
      )).isOk,
      isTrue,
    );
    await _drain();
    expect(aliceRestarted.channel.hasSession(bobRestarted.peerId), isTrue);
    expect(bobRestarted.channel.hasSession(aliceRestarted.peerId), isTrue);
    expect(restoredSessions, contains(bobRestarted.peerId));

    expect(
      await distribute(
        aliceRestarted,
        bobRestarted,
        MemorySenderKeyPackageStore(),
        _epoch + 1,
      ),
      hasLength(1),
    );
  });
}
