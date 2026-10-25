import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:core_sync/core_sync.dart' show hexDecode, hexEncode;
import 'package:test/test.dart';

const _groupId = GroupId('group-a');
const _alice = UserId(
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);
const _bob = UserId(
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
);
const _carol = UserId(
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
);

String _signatureFor(UserId sender, Uint8List data) {
  final signature = Uint8List(64);
  final identity = hexDecode(sender.value);
  if (identity == null || identity.length != 32) {
    throw ArgumentError.value(sender.value, 'sender', 'invalid identity');
  }
  signature.setRange(0, 32, identity);
  var hash = 0xcbf29ce484222325;
  for (final byte in data) {
    hash = ((hash ^ byte) * 0x100000001b3) & 0xffffffffffffffff;
  }
  for (var i = 0; i < 32; i++) {
    hash ^= hash >> 12;
    hash ^= (hash << 25) & 0xffffffffffffffff;
    hash ^= hash >> 27;
    signature[32 + i] = hash & 0xff;
  }
  return hexEncode(signature);
}

class _FakeSigner implements Signer {
  _FakeSigner(this.identity);

  final UserId identity;

  @override
  Future<String> sign(Uint8List data) async => _signatureFor(identity, data);

  @override
  Future<bool> verify(
    Uint8List data,
    String signatureHex,
    PeerId peerId,
  ) async {
    final signature = hexDecode(signatureHex);
    if (signature == null || signature.length != 64) return false;
    if (hexEncode(signature.sublist(0, 32)) != hexEncode(peerId.publicKey)) {
      return false;
    }
    return hexEncode(signature) ==
        _signatureFor(UserId(hexEncode(peerId.publicKey)), data);
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

class _InMemoryE2eChannel implements SenderKeyChannel {
  final codec = const SenderKeyPackageCodec();
  final recipients = <String, ProductionGroupKeyDistributor>{};
  final failFor = <String>{};
  final sent = <Uint8List>[];
  final received = <SenderKeyPackage>[];

  @override
  Future<Result<void, SenderKeyDeliveryError>> send(
    UserId recipient,
    Uint8List payload,
  ) async {
    sent.add(payload);
    if (failFor.contains(recipient.value)) {
      return Err(SenderKeyRecipientUnavailable(recipient));
    }
    final target = recipients[recipient.value];
    if (target == null) {
      return Err(SenderKeyRecipientUnavailable(recipient));
    }
    final decoded = codec.decode(payload);
    if (decoded.isErr) {
      return Err(SenderKeyDeliveryRejected(decoded.unwrapErr().toString()));
    }
    final package = decoded.unwrap();
    received.add(package);
    final accepted = await target.receive(package);
    if (accepted.isErr) {
      return Err(SenderKeyDeliveryRejected(accepted.unwrapErr().toString()));
    }
    return const Ok(null);
  }
}

SenderKeyPackage _package({
  UserId sender = _alice,
  UserId recipient = _bob,
  int epoch = 2,
  List<int> bytes = const [9, 8, 7],
  GroupId groupId = _groupId,
  String? signature,
}) {
  final base = SenderKeyPackage(
    groupId: groupId,
    epoch: epoch,
    sender: sender,
    recipient: recipient,
    keyPackage: Uint8List.fromList(bytes),
  );
  return base.withSignature(
    signature ?? _signatureFor(sender, base.signingBytes()),
  );
}

SenderKeyPackage _unsignedPackage({
  UserId sender = _alice,
  UserId recipient = _bob,
}) {
  return SenderKeyPackage(
    groupId: _groupId,
    epoch: 2,
    sender: sender,
    recipient: recipient,
    keyPackage: Uint8List.fromList(const [9, 8, 7]),
  );
}

GroupKeyRotation _rotation({
  UserId sender = _alice,
  Set<UserId>? recipients,
  int epoch = 2,
}) {
  return GroupKeyRotation(
    groupId: _groupId,
    epoch: epoch,
    sender: sender,
    recipients: recipients ?? <UserId>{_bob, _carol},
    keyPackage: Uint8List.fromList(const [9, 8, 7]),
  );
}

ProductionGroupKeyDistributor _distributor({
  required UserId localUser,
  required SenderKeyPackageStore store,
  required SenderKeyDelivery delivery,
}) {
  return ProductionGroupKeyDistributor(
    localUser: localUser,
    signer: _FakeSigner(localUser),
    delivery: delivery,
    store: store,
    verifier: const _AllowAllVerifier(),
  );
}

void main() {
  group('подпись sender-key пакета', () {
    test('исходящий пакет подписан и доставляется через E2E-канал', () async {
      final channel = _InMemoryE2eChannel();
      final bobStore = MemorySenderKeyPackageStore();
      final carolStore = MemorySenderKeyPackageStore();
      channel.recipients[_bob.value] = _distributor(
        localUser: _bob,
        store: bobStore,
        delivery: const UnavailableSenderKeyDelivery(),
      );
      channel.recipients[_carol.value] = _distributor(
        localUser: _carol,
        store: carolStore,
        delivery: const UnavailableSenderKeyDelivery(),
      );
      final alice = _distributor(
        localUser: _alice,
        store: MemorySenderKeyPackageStore(),
        delivery: E2eSenderKeyDelivery(channel: channel),
      );

      await alice.distribute(_rotation());

      expect(channel.sent, hasLength(2));
      expect(channel.received, hasLength(2));
      for (final package in channel.received) {
        expect(package.signature, isNotNull);
        expect(package.signature, isNotEmpty);
      }
      final bobVerified = await bobStore.load(
        _groupId,
        SenderKeyPackageState.verified,
      );
      expect(bobVerified.unwrap().single.package.sender, _alice);
      expect(bobVerified.unwrap().single.package.signature, isNotEmpty);
    });

    test('пакет без подписи и с изменённым телом уходит в карантин', () async {
      final store = MemorySenderKeyPackageStore();
      final bob = _distributor(
        localUser: _bob,
        store: store,
        delivery: const UnavailableSenderKeyDelivery(),
      );

      final unsigned = await bob.receive(_unsignedPackage());
      expect(unsigned.isErr, isTrue);

      final original = _package();
      final tampered = original
          .withSignature(original.signature!)
          .copyWith(
            epoch: 4,
            keyPackage: Uint8List.fromList(const [1, 2, 3, 4]),
          );
      final rejected = await bob.receive(tampered);
      expect(rejected.isErr, isTrue);

      final verified = await store.load(
        _groupId,
        SenderKeyPackageState.verified,
      );
      expect(verified.unwrap(), isEmpty);
      final quarantined = await store.load(
        _groupId,
        SenderKeyPackageState.quarantined,
      );
      expect(quarantined.unwrap(), hasLength(2));
      expect(
        quarantined.unwrap().every((e) => e.reason!.contains('signature')),
        isTrue,
      );
    });

    test('подпись привязана к получателю и эпохе', () async {
      final signed = _package();
      final carolStore = MemorySenderKeyPackageStore();
      final carol = _distributor(
        localUser: _carol,
        store: carolStore,
        delivery: const UnavailableSenderKeyDelivery(),
      );
      final wrongRecipient = signed.copyWith(recipient: _carol);

      final result = await carol.receive(wrongRecipient);

      expect(result.isErr, isTrue);
      final verified = await carolStore.load(
        _groupId,
        SenderKeyPackageState.verified,
      );
      expect(verified.unwrap(), isEmpty);
    });

    test('чужой ключ подписи не подписывает исходящую ротацию', () async {
      final channel = _InMemoryE2eChannel();
      final store = MemorySenderKeyPackageStore();
      final alice = ProductionGroupKeyDistributor(
        localUser: _alice,
        signer: _FakeSigner(_bob),
        delivery: E2eSenderKeyDelivery(channel: channel),
        store: store,
        verifier: const _AllowAllVerifier(),
      );

      await alice.distribute(_rotation());

      expect(channel.sent, isEmpty);
      expect(alice.lastError, isA<InvalidSenderKeyPackage>());
      final pending = await store.load(_groupId, SenderKeyPackageState.pending);
      expect(pending.unwrap(), isEmpty);
    });

    test('без signer рассылка и приём fail-closed', () async {
      final channel = _InMemoryE2eChannel();
      final store = MemorySenderKeyPackageStore();
      final alice = ProductionGroupKeyDistributor(
        localUser: _alice,
        delivery: E2eSenderKeyDelivery(channel: channel),
        store: store,
        verifier: const _AllowAllVerifier(),
      );

      await alice.distribute(_rotation());

      expect(channel.sent, isEmpty);
      expect(alice.lastError, isA<InvalidSenderKeyPackage>());
      expect(
        (await store.load(_groupId, SenderKeyPackageState.pending)).unwrap(),
        isEmpty,
      );

      final bobStore = MemorySenderKeyPackageStore();
      final bob = ProductionGroupKeyDistributor(
        localUser: _bob,
        delivery: const UnavailableSenderKeyDelivery(),
        store: bobStore,
        verifier: const _AllowAllVerifier(),
      );
      final rejected = await bob.receive(_package());

      expect(rejected.isErr, isTrue);
      expect(
        (await bobStore.load(
          _groupId,
          SenderKeyPackageState.verified,
        )).unwrap(),
        isEmpty,
      );
      final quarantined = await bobStore.load(
        _groupId,
        SenderKeyPackageState.quarantined,
      );
      expect(quarantined.unwrap().single.reason, contains('signer'));
    });

    test('E2eSenderKeyDelivery не отправляет неподписанный пакет', () async {
      final channel = _InMemoryE2eChannel();
      final delivery = E2eSenderKeyDelivery(channel: channel);

      final result = await delivery.deliver(_unsignedPackage());

      expect(result.isErr, isTrue);
      expect(channel.sent, isEmpty);
    });
  });

  group('E2E-доставка sender keys', () {
    test('неудачная доставка остаётся pending и повторяется', () async {
      final channel = _InMemoryE2eChannel()
        ..failFor.add(_bob.value)
        ..recipients[_bob.value] = _distributor(
          localUser: _bob,
          store: MemorySenderKeyPackageStore(),
          delivery: const UnavailableSenderKeyDelivery(),
        )
        ..recipients[_carol.value] = _distributor(
          localUser: _carol,
          store: MemorySenderKeyPackageStore(),
          delivery: const UnavailableSenderKeyDelivery(),
        );
      final store = MemorySenderKeyPackageStore();
      final alice = _distributor(
        localUser: _alice,
        store: store,
        delivery: E2eSenderKeyDelivery(channel: channel),
      );

      await alice.distribute(_rotation());

      final pending = await store.load(_groupId, SenderKeyPackageState.pending);
      expect(pending.unwrap().single.package.recipient, _bob);

      channel.failFor.clear();
      final restarted = _distributor(
        localUser: _alice,
        store: store,
        delivery: E2eSenderKeyDelivery(channel: channel),
      );
      final retried = await restarted.retryPending(_groupId);

      expect(retried.isOk, isTrue);
      expect(retried.unwrap().delivered, 1);
      final bobStore = channel.recipients[_bob.value]!.store;
      final verified = await bobStore.load(
        _groupId,
        SenderKeyPackageState.verified,
      );
      expect(verified.unwrap().single.package.signature, isNotEmpty);
      final left = await store.load(_groupId, SenderKeyPackageState.pending);
      expect(left.unwrap(), isEmpty);
    });

    test('restore перепроверяет подпись после рестарта', () async {
      final store = MemorySenderKeyPackageStore();
      final good = _package(epoch: 2);
      final bad = _package(epoch: 3);
      await store.save(
        StoredSenderKeyPackage(
          package: good,
          state: SenderKeyPackageState.verified,
        ),
      );
      await store.save(
        StoredSenderKeyPackage(
          package: bad.copyWith(
            keyPackage: Uint8List.fromList(const [7, 7, 7]),
          ),
          state: SenderKeyPackageState.verified,
        ),
      );
      final bob = _distributor(
        localUser: _bob,
        store: store,
        delivery: const UnavailableSenderKeyDelivery(),
      );

      final restored = await bob.restore(_groupId);

      expect(restored.unwrap().map((p) => p.epoch), [2]);
      final quarantined = await store.load(
        _groupId,
        SenderKeyPackageState.quarantined,
      );
      expect(quarantined.unwrap().single.package.epoch, 3);
    });
  });
}
