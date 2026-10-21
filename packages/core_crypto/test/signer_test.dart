import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

String bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

List<int> hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}

/// RFC 8032 §7.1 test vectors (источник: https://www.rfc-editor.org/rfc/rfc8032.html, раздел 7.1).
/// TEST 1: пустое сообщение.
const _rfc8032Test1SecretKey =
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';
const _rfc8032Test1PublicKey =
    'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
const _rfc8032Test1Signature =
    'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b';

/// TEST 2: 1-байтное сообщение 0x72.
const _rfc8032Test2SecretKey =
    '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb';
const _rfc8032Test2PublicKey =
    '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c';
const _rfc8032Test2Message = '72';
const _rfc8032Test2Signature =
    '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00';

void main() {
  group('CryptoSigner', () {
    test('sign/verify roundtrip with raw bytes', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);

      final signature = await signer.sign(data);
      expect(signature, isNotEmpty);
      expect(signature, hasLength(128)); // 64 bytes hex

      final valid = await signer.verify(data, signature, identity.peerId);
      expect(valid, isTrue);
    });

    test('changed 1 bit of data fails verification', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);

      final signature = await signer.sign(data);
      final tampered = Uint8List.fromList(data);
      tampered[0] ^= 0x01; // flip 1 bit

      final valid = await signer.verify(tampered, signature, identity.peerId);
      expect(valid, isFalse);
    });

    test('foreign PeerId fails verification', () async {
      final identityA = await generateIdentity();
      final identityB = await generateIdentity();
      final signerA = CryptoSigner(identityA.ed25519PrivateKey);
      final signerB = CryptoSigner(identityB.ed25519PrivateKey);
      final data = Uint8List.fromList([7, 8, 9]);

      final signature = await signerA.sign(data);
      final validB = await signerB.verify(
        data,
        signature,
        identityB.peerId,
      );
      expect(validB, isFalse);
    });

    test('truncated signature fails verification', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([1, 2, 3]);

      final signature = await signer.sign(data);
      final truncated = signature.substring(0, 60); // 30 bytes instead of 64

      final valid = await signer.verify(data, truncated, identity.peerId);
      expect(valid, isFalse);
    });

    test('extended signature fails verification', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([1, 2, 3]);

      final signature = await signer.sign(data);
      final extended = '${signature}ff'; // 65 bytes

      final valid = await signer.verify(data, extended, identity.peerId);
      expect(valid, isFalse);
    });

    test('empty data signs and verifies', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([]);

      final signature = await signer.sign(data);
      expect(signature, hasLength(128));

      final valid = await signer.verify(data, signature, identity.peerId);
      expect(valid, isTrue);
    });

    test('non-hex signature returns false', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([1, 2, 3]);

      final valid = await signer.verify(data, 'not-hex!!', identity.peerId);
      expect(valid, isFalse);
    });

    test('empty signature returns false', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([1, 2, 3]);

      final valid = await signer.verify(data, '', identity.peerId);
      expect(valid, isFalse);
    });

    test('signature from another key does not verify', () async {
      final identityA = await generateIdentity();
      final identityB = await generateIdentity();
      final signerA = CryptoSigner(identityA.ed25519PrivateKey);
      final signerB = CryptoSigner(identityB.ed25519PrivateKey);
      final data = Uint8List.fromList([42, 43, 44]);

      final sigA = await signerA.sign(data);
      final validB = await signerB.verify(
        data,
        sigA,
        identityB.peerId,
      );
      expect(validB, isFalse);
    });

    test('PeerId with wrong key length returns false', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([1, 2, 3]);

      final signature = await signer.sign(data);
      final badPeerId = PeerId(Uint8List.fromList(List<int>.filled(16, 0)));

      final valid = await signer.verify(data, signature, badPeerId);
      expect(valid, isFalse);
    });

    test('RFC 8032 §7.1 TEST 1: deterministic signature for empty message matches vector',
        () async {
      final algo = Ed25519();
      final seed = hexToBytes(_rfc8032Test1SecretKey);
      final keyPair = await algo.newKeyPairFromSeed(seed);
      final pubKey = await keyPair.extractPublicKey();

      expect(
        bytesToHex(pubKey.bytes),
        equals(_rfc8032Test1PublicKey),
        reason:
            'derived public key must match RFC 8032 §7.1 TEST 1 public key',
      );

      final signature = await algo.sign(
        Uint8List.fromList([]),
        keyPair: keyPair,
      );
      final sigHex = bytesToHex(signature.bytes);

      expect(
        sigHex,
        equals(_rfc8032Test1Signature),
        reason:
            'deterministic Ed25519 signature must match RFC 8032 §7.1 TEST 1 signature',
      );

      final ok = await algo.verify(
        Uint8List.fromList([]),
        signature: signature,
      );
      expect(ok, isTrue);
    });

    test('RFC 8032 §7.1 TEST 2: signature for 1-byte message matches vector',
        () async {
      final algo = Ed25519();
      final seed = hexToBytes(_rfc8032Test2SecretKey);
      final keyPair = await algo.newKeyPairFromSeed(seed);
      final pubKey = await keyPair.extractPublicKey();

      expect(
        bytesToHex(pubKey.bytes),
        equals(_rfc8032Test2PublicKey),
        reason:
            'derived public key must match RFC 8032 §7.1 TEST 2 public key',
      );

      final message = hexToBytes(_rfc8032Test2Message);
      final signature = await algo.sign(message, keyPair: keyPair);
      final sigHex = bytesToHex(signature.bytes);

      expect(
        sigHex,
        equals(_rfc8032Test2Signature),
        reason:
            'deterministic Ed25519 signature must match RFC 8032 §7.1 TEST 2 signature',
      );
    });

    test('same key produces identical signatures for same data (determinism)',
        () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([9, 8, 7]);

      final sig1 = await signer.sign(data);
      final sig2 = await signer.sign(data);
      expect(sig1, equals(sig2));
    });

    test('signer uses public key derived from same seed as private key',
        () async {
      // Regression test for D-02: the public key embedded in the signing
      // key pair must match the private key's seed — no temp key pair.
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);
      final data = Uint8List.fromList([1, 2, 3]);

      final signature = await signer.sign(data);
      final valid = await signer.verify(data, signature, identity.peerId);
      expect(valid, isTrue);

      // The peerId public key must equal the Ed25519 public key.
      final edPubBytes = (identity.ed25519PublicKey as SimplePublicKey).bytes;
      expect(identity.peerId.publicKey, equals(edPubBytes));
    });
  });
}