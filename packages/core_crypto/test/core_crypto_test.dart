import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

void main() {
  group('CryptoSigner', () {
    test('generateIdentity creates non-empty key pair', () async {
      final identity = await generateIdentity();
      expect(identity.userId.value, isNotEmpty);
      expect((identity.ed25519PublicKey as SimplePublicKey).bytes, isNotEmpty);
      expect(identity.userId.value,
          bytesToHex((identity.ed25519PublicKey as SimplePublicKey).bytes));
    });

    test('sign/verify roundtrip passes', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);

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

    test('signature of another key does not verify', () async {
      final identityA = await generateIdentity();
      final identityB = await generateIdentity();
      final signerA = CryptoSigner(identityA.ed25519PrivateKey);
      final signerB = CryptoSigner(identityB.ed25519PrivateKey);
      final data = Uint8List.fromList([7, 8, 9]);

      final signature = await signerA.sign(data);
      final validA = await signerA.verify(data, signature, identityA.peerId);
      expect(validA, isTrue);

      final validB = await signerB.verify(data, signature, identityB.peerId);
      expect(validB, isFalse);
    });
  });

  group('FakeSecureKeyStore', () {
    test('stores and loads IdentityBundle', () async {
      final store = FakeSecureKeyStore();
      const userId = UserId('u-1');
      final has = await store.hasIdentity(userId);
      expect(has.isOk, isTrue);
      expect((has as Ok<bool, KeyStoreError>).value, isFalse);

      final stored = await store.storeIdentity(
        userId,
        const IdentityBundle(
          userId: UserId('u-1'),
          publicKey: 'pk-hex',
          privateSeed: [1, 2],
          createdAt: 5,
        ),
      );
      expect(stored.isOk, isTrue);

      final hasAfter = await store.hasIdentity(userId);
      expect(hasAfter.isOk, isTrue);
      expect((hasAfter as Ok<bool, KeyStoreError>).value, isTrue);
      final loaded = await store.loadIdentity(userId);
      expect(loaded.isOk, isTrue);
      expect((loaded as Ok<IdentityBundle, KeyStoreError>).value.publicKey, 'pk-hex');

      final deleted = await store.deleteIdentity(userId);
      expect(deleted.isOk, isTrue);
      final hasDeleted = await store.hasIdentity(userId);
      expect(hasDeleted.isOk, isTrue);
      expect((hasDeleted as Ok<bool, KeyStoreError>).value, isFalse);
      final loadedAgain = await store.loadIdentity(userId);
      expect(loadedAgain.isErr, isTrue);
      expect(loadedAgain.unwrapErr(), isA<IdentityNotFound>());
    });
  });
}
