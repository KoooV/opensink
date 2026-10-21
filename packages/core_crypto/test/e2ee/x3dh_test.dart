import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:test/test.dart';

List<int> hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}

Uint8List hexToUint8List(String hex) {
  return Uint8List.fromList(hexToBytes(hex));
}

String bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

void main() {
  group('X3DH (RFC 7748 §6.1 X25519 DH test vector)', () {
    // Источник: RFC 7748, раздел 6.1 "Curve25519", тестовый вектор DH.
    // Alice's private key: 77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a
    // Alice's public key:  8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a
    // Bob's private key:   5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb
    // Bob's public key:    de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f
    // Shared secret:       4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742
    test('X25519 shared secret matches RFC 7748 §6.1', () async {
      const alicePrivHex =
          '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a';
      const alicePubHex =
          '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a';
      const bobPrivHex =
          '5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb';
      const bobPubHex =
          'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f';
      const sharedSecretHex =
          '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742';

      final x25519 = X25519();

      // Alice's key pair from her private key seed.
      final alicePair = await x25519.newKeyPairFromSeed(
        hexToUint8List(alicePrivHex),
      );
      final alicePub = await alicePair.extractPublicKey();
      expect(bytesToHex(alicePub.bytes), alicePubHex);

      // Bob's key pair from his private key seed.
      final bobPair = await x25519.newKeyPairFromSeed(hexToUint8List(bobPrivHex));
      final bobPub = await bobPair.extractPublicKey();
      expect(bytesToHex(bobPub.bytes), bobPubHex);

      // Alice computes shared secret with Bob's public key.
      final aliceShared = await x25519.sharedSecretKey(
        keyPair: alicePair,
        remotePublicKey: bobPub,
      );
      final aliceSharedBytes = await aliceShared.extractBytes();
      expect(bytesToHex(aliceSharedBytes), sharedSecretHex);

      // Bob computes shared secret with Alice's public key.
      final bobShared = await x25519.sharedSecretKey(
        keyPair: bobPair,
        remotePublicKey: alicePub,
      );
      final bobSharedBytes = await bobShared.extractBytes();
      expect(bytesToHex(bobSharedBytes), sharedSecretHex);
    });
  });

  group('X3DH roundtrip', () {
    test('sender and receiver derive the same shared key', () async {
      final x3dh = X3DH();

      // Alice генерирует свой ключевой бандл (IK + SPK + подпись).
      final aliceBundle = await x3dh.generateKeyBundle();

      // Bob в роли отправителя вычисляет общий секрет с помощью публичного бандла Alice.
      final senderResult = await x3dh.sender(
        remoteBundle: aliceBundle.toPublicBundle(),
      );
      expect(senderResult.isOk, isTrue);
      final senderShared = (senderResult as Ok<X3DHSenderResult, CryptoError>)
          .value
          .sharedKey;

      // Alice в роли получателя вычисляет тот же секрет с использованием
      // эфемерного открытого ключа Bob.
      final receiverShared = await x3dh.receiver(
        bundle: aliceBundle,
        senderEphemeralPublicKey: senderResult.unwrap().ephemeralPublicKey,
      );

      final senderBytes = await senderShared.extractBytes();
      final receiverBytes = await receiverShared.extractBytes();
      expect(bytesToHex(senderBytes), bytesToHex(receiverBytes));
    });

    test('different key bundles produce different shared keys', () async {
      final x3dh = X3DH();

      final bundle1 = await x3dh.generateKeyBundle();
      final bundle2 = await x3dh.generateKeyBundle();

      final result1 = await x3dh.sender(remoteBundle: bundle1.toPublicBundle());
      final result2 = await x3dh.sender(remoteBundle: bundle2.toPublicBundle());

      expect(result1.isOk, isTrue);
      expect(result2.isOk, isTrue);

      final shared1 = await (result1 as Ok).value.sharedKey.extractBytes();
      final shared2 = await (result2 as Ok).value.sharedKey.extractBytes();

      expect(bytesToHex(shared1), isNot(bytesToHex(shared2)));
    });

    test('invalid SPK binding → rejection before DH computations', () async {
      final x3dh = X3DH();

      final bundle = await x3dh.generateKeyBundle();
      final publicBundle = bundle.toPublicBundle();

      // Подменяем подпись — теперь она не соответствует SPK.
      final tampered = X3DHPublicBundle(
        identityKey: publicBundle.identityKey,
        signedPrekey: publicBundle.signedPrekey,
        ed25519PublicKey: publicBundle.ed25519PublicKey,
        signedPrekeySignature:
            '0000000000000000000000000000000000000000000000000000000000000000',
      );

      final result = await x3dh.sender(remoteBundle: tampered);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidSignature>());
    });

    test('bundle without SPK binding signature → rejection', () async {
      final x3dh = X3DH();

      final bundle = await x3dh.generateKeyBundle();
      final noSigBundle = X3DHPublicBundle(
        identityKey: bundle.identityKey,
        signedPrekey: bundle.signedPrekey,
        ed25519PublicKey: bundle.ed25519PublicKey,
        signedPrekeySignature: null,
      );

      final result = await x3dh.sender(remoteBundle: noSigBundle);
      expect(result.isErr, isTrue);
    });
  });

  group('X3DH no OPK', () {
    test('sender works without one-time prekey', () async {
      final x3dh = X3DH();
      final bundle = await x3dh.generateKeyBundle();

      final result = await x3dh.sender(remoteBundle: bundle.toPublicBundle());
      expect(result.isOk, isTrue);
      final sharedKey = (result as Ok<X3DHSenderResult, CryptoError>).value
          .sharedKey;
      final bytes = await sharedKey.extractBytes();
      expect(bytes, hasLength(32));
    });
  });
}
