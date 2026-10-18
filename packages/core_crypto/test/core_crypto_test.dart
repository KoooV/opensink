import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_domain/src/events/group_event.dart';

void main() {
  const testPeer = PeerId(Uint8List.fromList([1, 2, 3, 4]));

  group('CryptoSigner', () {
    test('generateIdentity создаёт непустую пару ключей', () async {
      final identity = await generateIdentity();
      expect(identity.userId.value, isNotEmpty);
      expect(identity.publicKey.hex, isNotEmpty);
      expect(identity.userId.value, identity.publicKey.hex);
    });

    test('sign/verify roundtrip проходит', () async {
      final identity = await generateIdentity();
      const signer = CryptoSigner(identity.privateKey);
      const data = Uint8List.fromList([1, 2, 3, 4, 5]);

      final signature = await signer.sign(data);
      expect(signature, isNotEmpty);

      final valid = await signer.verify(data, signature, identity.peerId);
      expect(valid, isTrue);

      final invalid = await signer.verify(
        Uint8List.fromList([9, 9, 9]),
        signature,
        identity.peerId,
      );
      expect(invalid, isFalse);
    });

    test('подпись другого ключа не верифицируется', () async {
      final identityA = await generateIdentity();
      final identityB = await generateIdentity();
      const signerA = CryptoSigner(identityA.privateKey);
      const signerB = CryptoSigner(identityB.privateKey);
      const data = Uint8List.fromList([7, 8, 9]);

      final signature = await signerA.sign(data);
      final validA = await signerA.verify(data, signature, identityA.peerId);
      expect(validA, isTrue);

      final validB = await signerB.verify(data, signature, identityB.peerId);
      expect(validB, isFalse);
    });

    test('signEvent / verifyEvent с GroupEvent', () async {
      final identity = await generateIdentity();
      const signer = CryptoSigner(identity.privateKey);
      final event = GroupCreated(
        id: EventId('evt-1'),
        groupId: GroupId('g-1'),
        authorId: UserId('u-1'),
        timestamp: 1000,
        signature: '',
        name: 'Test Group',
        ownerId: UserId('u-1'),
        initialMembers: {UserId('u-1')},
      );

      final signature = await signer.signEvent(event);

      final valid = await signer.verifyEvent(
        GroupCreated(
          id: event.id,
          groupId: event.groupId,
          authorId: event.authorId,
          timestamp: event.timestamp,
          signature: signature,
          name: event.name,
          ownerId: event.ownerId,
          initialMembers: event.initialMembers,
        ),
      );
      expect(valid, isTrue);
    });
  });

  group('FakeSecureKeyStore', () {
    test('хранит и удаляет IdentityBundle', () async {
      final store = FakeSecureKeyStore();
      final userId = UserId('u-1');
      expect(await store.hasIdentity(userId), isFalse);

      await store.storeIdentity(
        userId,
        const IdentityBundle(
          userId: UserId('u-1'),
          publicKey: 'pk-hex',
          encryptedPrivateKey: [1, 2],
          createdAt: 5,
        ),
      );

      expect(await store.hasIdentity(userId), isTrue);
      final loaded = await store.loadIdentity(userId);
      expect(loaded, isNotNull);
      expect(loaded?.publicKey, 'pk-hex');

      await store.deleteIdentity(userId);
      expect(await store.hasIdentity(userId), isFalse);
      expect(await store.loadIdentity(userId), isNull);
    });
  });
}
