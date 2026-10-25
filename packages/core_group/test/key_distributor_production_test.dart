import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
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

class _FakeDelivery implements SenderKeyDelivery {
  final List<SenderKeyPackage> packages = <SenderKeyPackage>[];
  final Set<String> failFor = <String>{};

  @override
  Future<Result<void, SenderKeyDeliveryError>> deliver(
    SenderKeyPackage package,
  ) async {
    packages.add(package);
    if (failFor.contains(package.recipient.value)) {
      return Err(SenderKeyRecipientUnavailable(package.recipient));
    }
    return const Ok(null);
  }
}

class _FakeVerifier implements SenderKeyPackageVerifier {
  final Set<String> rejectFor = <String>{};

  @override
  Future<Result<void, SenderKeyPackageError>> verify(
    SenderKeyPackage package,
  ) async {
    if (rejectFor.contains(package.recipient.value)) {
      return const Err(InvalidSenderKeyPackage('signature mismatch'));
    }
    return const Ok(null);
  }
}

SenderKeyPackage _package({
  UserId recipient = _alice,
  UserId sender = _bob,
  int epoch = 2,
  List<int> bytes = const [1, 2, 3],
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

GroupKeyRotation _rotation({
  UserId sender = _alice,
  Set<UserId>? recipients,
  int epoch = 2,
  List<int> keyPackage = const [9, 8, 7],
  String? signature,
}) {
  return GroupKeyRotation(
    groupId: _groupId,
    epoch: epoch,
    sender: sender,
    recipients: recipients ?? <UserId>{_bob, _carol},
    keyPackage: Uint8List.fromList(keyPackage),
    signature: signature,
  );
}

ProductionGroupKeyDistributor _distributor(
  _FakeDelivery delivery,
  MemorySenderKeyPackageStore store, {
  SenderKeyPackageVerifier? verifier,
  UserId localUser = _alice,
}) {
  return ProductionGroupKeyDistributor(
    localUser: localUser,
    signer: _FakeSigner(localUser),
    delivery: delivery,
    store: store,
    verifier: verifier ?? _FakeVerifier(),
  );
}

List<String> _recipients(Iterable<SenderKeyPackage> packages) =>
    packages.map((package) => package.recipient.value).toList()..sort();

void main() {
  group('ProductionGroupKeyDistributor', () {
    test('рассылает пакет каждому получателю и отмечает delivered', () async {
      final delivery = _FakeDelivery();
      final store = MemorySenderKeyPackageStore();
      final distributor = _distributor(delivery, store);

      await distributor.distribute(_rotation());

      expect(_recipients(delivery.packages), [_bob.value, _carol.value]);
      final delivered = await store.load(
        _groupId,
        SenderKeyPackageState.delivered,
      );
      expect(delivered.isOk, isTrue);
      expect(_recipients(delivered.unwrap().map((e) => e.package)), [
        _bob.value,
        _carol.value,
      ]);
      expect(delivery.packages.first.keyPackage, [9, 8, 7]);
    });

    test(
      'неудачная доставка остаётся pending и повторяется после рестарта',
      () async {
        final delivery = _FakeDelivery()..failFor.add(_bob.value);
        final store = MemorySenderKeyPackageStore();
        final first = _distributor(delivery, store);

        await first.distribute(_rotation());

        var pending = await store.load(_groupId, SenderKeyPackageState.pending);
        expect(pending.unwrap().map((e) => e.package.recipient.value), [
          _bob.value,
        ]);

        delivery.failFor.clear();
        final restarted = _distributor(delivery, store);
        final retried = await restarted.retryPending(_groupId);

        expect(retried.isOk, isTrue);
        expect(retried.unwrap().delivered, 1);
        pending = await store.load(_groupId, SenderKeyPackageState.pending);
        expect(pending.unwrap(), isEmpty);
        final delivered = await store.load(
          _groupId,
          SenderKeyPackageState.delivered,
        );
        expect(delivered.unwrap(), hasLength(2));
      },
    );

    test(
      'входящий пакет проходит проверку и попадает в verified-кэш',
      () async {
        final delivery = _FakeDelivery();
        final store = MemorySenderKeyPackageStore();
        final distributor = _distributor(delivery, store);

        final accepted = await distributor.receive(_package());

        expect(accepted.isOk, isTrue);
        expect(delivery.packages, isEmpty);
        final verified = await store.load(
          _groupId,
          SenderKeyPackageState.verified,
        );
        expect(verified.unwrap().single.package.sender, _bob);
      },
    );

    test(
      'невалидный входящий пакет уходит в карантин, не в verified',
      () async {
        final delivery = _FakeDelivery();
        final store = MemorySenderKeyPackageStore();
        final verifier = _FakeVerifier()..rejectFor.add(_alice.value);
        final distributor = _distributor(delivery, store, verifier: verifier);

        final rejected = await distributor.receive(_package());

        expect(rejected.isErr, isTrue);
        expect(rejected.unwrapErr(), isA<InvalidSenderKeyPackage>());
        final verified = await store.load(
          _groupId,
          SenderKeyPackageState.verified,
        );
        expect(verified.unwrap(), isEmpty);
        final quarantined = await store.load(
          _groupId,
          SenderKeyPackageState.quarantined,
        );
        expect(quarantined.unwrap().single.reason, contains('signature'));
      },
    );

    test('restore карантинит испорченный пакет и сохраняет валидный', () async {
      final delivery = _FakeDelivery();
      final store = MemorySenderKeyPackageStore();
      final good = _package(recipient: _alice, epoch: 2);
      final bad = _package(recipient: _alice, epoch: 3, bytes: const [4]);
      await store.save(
        StoredSenderKeyPackage(
          package: good,
          state: SenderKeyPackageState.verified,
        ),
      );
      await store.save(
        StoredSenderKeyPackage(
          package: bad,
          state: SenderKeyPackageState.verified,
        ),
      );
      final verifier = _RejectEpochVerifier(3);
      final resting = _distributor(delivery, store, verifier: verifier);

      final restored = await resting.restore(_groupId);

      expect(restored.unwrap().map((p) => p.epoch), [2]);
      final verified = await store.load(
        _groupId,
        SenderKeyPackageState.verified,
      );
      expect(verified.unwrap().map((e) => e.package.epoch), [2]);
      final quarantined = await store.load(
        _groupId,
        SenderKeyPackageState.quarantined,
      );
      expect(quarantined.unwrap().map((e) => e.package.epoch), [3]);
    });

    test('чужая ротация не рассылается от локального пользователя', () async {
      final delivery = _FakeDelivery();
      final store = MemorySenderKeyPackageStore();
      final distributor = _distributor(delivery, store);

      final remotePackage = SenderKeyPackage(
        groupId: _groupId,
        epoch: 2,
        sender: _bob,
        recipient: _alice,
        keyPackage: Uint8List.fromList(const [9, 8, 7]),
      );
      await distributor.distribute(
        _rotation(
          sender: _bob,
          recipients: <UserId>{_alice, _carol},
          signature: _signatureFor(_bob, remotePackage.signingBytes()),
        ),
      );

      expect(delivery.packages, isEmpty);
      final verified = await store.load(
        _groupId,
        SenderKeyPackageState.verified,
      );
      expect(verified.unwrap().single.package.sender, _bob);
      expect(verified.unwrap().single.package.recipient, _alice);
    });

    test(
      'невалидная локальная ротация не доставляется и даёт ошибку',
      () async {
        final delivery = _FakeDelivery();
        final store = MemorySenderKeyPackageStore();
        final distributor = _distributor(delivery, store);

        await distributor.distribute(_rotation(keyPackage: const []));

        expect(delivery.packages, isEmpty);
        expect(distributor.lastError, isA<InvalidSenderKeyPackage>());
        final pending = await store.load(
          _groupId,
          SenderKeyPackageState.pending,
        );
        expect(pending.unwrap(), isEmpty);
      },
    );
  });
}

class _RejectEpochVerifier implements SenderKeyPackageVerifier {
  _RejectEpochVerifier(this.epoch);

  final int epoch;

  @override
  Future<Result<void, SenderKeyPackageError>> verify(
    SenderKeyPackage package,
  ) async {
    if (package.epoch == epoch) {
      return const Err(InvalidSenderKeyPackage('tampered package'));
    }
    return const Ok(null);
  }
}
