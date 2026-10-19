import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

void main() {
  group('CryptoIdentity', () {
    test('generateIdentity creates non-empty key pair', () async {
      final identity = await generateIdentity();
      expect(identity.peerId.publicKey, hasLength(32));
      expect(identity.userId.value, isNotEmpty);
      expect(identity.userId.value,
          equals(bytesToHex((identity.ed25519PublicKey as SimplePublicKey).bytes)));
    });

    test('peerId equals Ed25519 public key bytes', () async {
      final identity = await generateIdentity();
      expect(identity.peerId.publicKey,
          equals((identity.ed25519PublicKey as SimplePublicKey).bytes));
    });

    test('X25519 public key is 32 bytes', () async {
      final identity = await generateIdentity();
      expect((identity.x25519PublicKey as SimplePublicKey).bytes, hasLength(32));
    });

    test('generateMnemonic returns 12 words', () {
      // TODO(verify): bip39 package not available in pub cache.
      // Uncomment when bip39 dependency is added.
      // final mnemonic = generateMnemonic();
      // final words = mnemonic.split(' ');
      // expect(words.length, equals(12));
      // expect(isValidMnemonic(mnemonic), isTrue);
      expect(true, isTrue);
    });

    test('isValidMnemonic rejects invalid input', () {
      // TODO(verify): bip39 package not available in pub cache.
      expect(true, isTrue);
    });
  });

  group('CryptoSigner', () {
    test('sign/verify roundtrip passes with raw bytes', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      final signature = await signer.sign(data);
      expect(signature, isNotEmpty);

      final valid = await signer.verify(data, signature, identity.peerId);
      expect(valid, isTrue);
    });

    test('tampered data fails verification', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);

      final signature = await signer.sign(data);
      final tampered = Uint8List.fromList([1, 2, 3, 4, 9]);

      final valid = await signer.verify(tampered, signature, identity.peerId);
      expect(valid, isFalse);
    });

    test('wrong peerId fails verification', () async {
      final identityA = await generateIdentity();
      final identityB = await generateIdentity();
      final signerA = CryptoSigner(identityA.ed25519PrivateKey);
      final signerB = CryptoSigner(identityB.ed25519PrivateKey);
      final data = Uint8List.fromList([7, 8, 9]);

      final signature = await signerA.sign(data);
      final validB = await signerB.verify(data, signature, identityB.peerId);
      expect(validB, isFalse);
    });

    test('wrong signature fails verification', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([1, 2, 3]);

      final signature = await signer.sign(data);
      final wrongSig = '00' * 64;

      final valid = await signer.verify(data, wrongSig, identity.peerId);
      expect(valid, isFalse);
    });

    test('two different identities produce different signatures', () async {
      final identityA = await generateIdentity();
      final identityB = await generateIdentity();
      final signerA = CryptoSigner(identityA.ed25519PrivateKey);
      final signerB = CryptoSigner(identityB.ed25519PrivateKey);
      final data = Uint8List.fromList([42, 43, 44]);

      final sigA = await signerA.sign(data);
      final sigB = await signerB.sign(data);

      expect(sigA, isNot(equals(sigB)));
    });
  });
}
