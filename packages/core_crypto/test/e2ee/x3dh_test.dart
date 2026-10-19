import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

void main() {
  group('X3DH', () {
    test('sender and receiver derive the same shared key', () async {
      final x3dh = X3DH();

      // Receiver generates key bundle
      final receiverBundle = await x3dh.generateKeyBundle();
      final publicBundle = receiverBundle.toPublicBundle();

      // Sender performs handshake
      final senderResult = await x3dh.sender(
        remoteBundle: publicBundle,
        useOneTimePrekey: true,
      );

      // Receiver performs handshake
      final sharedKey = await x3dh.receiver(
        bundle: receiverBundle,
        senderEphemeralPublicKey: senderResult.ephemeralPublicKey,
        usedOneTimePrekey: senderResult.usedOneTimePrekey,
      );

      final senderBytes = await senderResult.sharedKey.extractBytes();
      final receiverBytes = await sharedKey.extractBytes();

      expect(senderBytes, equals(receiverBytes));
      expect(senderBytes, hasLength(32));
    });

    test('sender without one-time prekey still works', () async {
      final x3dh = X3DH();

      final receiverBundle = await x3dh.generateKeyBundle();
      final publicBundle = receiverBundle.toPublicBundle();

      final senderResult = await x3dh.sender(
        remoteBundle: publicBundle,
        useOneTimePrekey: false,
      );

      expect(senderResult.usedOneTimePrekey, isFalse);

      final sharedKey = await x3dh.receiver(
        bundle: receiverBundle,
        senderEphemeralPublicKey: senderResult.ephemeralPublicKey,
        usedOneTimePrekey: false,
      );

      final senderBytes = await senderResult.sharedKey.extractBytes();
      final receiverBytes = await sharedKey.extractBytes();
      expect(senderBytes, equals(receiverBytes));
    });

    test('different key bundles produce different shared keys', () async {
      final x3dh = X3DH();

      final bundleA = await x3dh.generateKeyBundle();
      final bundleB = await x3dh.generateKeyBundle();

      final publicBundleA = bundleA.toPublicBundle();
      final publicBundleB = bundleB.toPublicBundle();

      final senderResultA = await x3dh.sender(remoteBundle: publicBundleA);
      final senderResultB = await x3dh.sender(remoteBundle: publicBundleB);

      final sharedKeyA = await x3dh.receiver(
        bundle: bundleA,
        senderEphemeralPublicKey: senderResultA.ephemeralPublicKey,
        usedOneTimePrekey: senderResultA.usedOneTimePrekey,
      );
      final sharedKeyB = await x3dh.receiver(
        bundle: bundleB,
        senderEphemeralPublicKey: senderResultB.ephemeralPublicKey,
        usedOneTimePrekey: senderResultB.usedOneTimePrekey,
      );

      final bytesA = await sharedKeyA.extractBytes();
      final bytesB = await sharedKeyB.extractBytes();
      expect(bytesA, isNot(equals(bytesB)));
    });
  });

  group('x3dhToSessionKeys', () {
    test('produces three independent keys', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey.fromBytes(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );

      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final rootBytes = await sessionKeys.rootKey.extractBytes();
      final sendBytes = await sessionKeys.sendingChainKey.extractBytes();
      final recvBytes = await sessionKeys.receivingChainKey.extractBytes();

      expect(rootBytes, hasLength(32));
      expect(sendBytes, hasLength(32));
      expect(recvBytes, hasLength(32));
      expect(rootBytes, isNot(equals(sendBytes)));
      expect(rootBytes, isNot(equals(recvBytes)));
      expect(sendBytes, isNot(equals(recvBytes)));
    });

    test('same shared secret produces same session keys (deterministic)', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey.fromBytes(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );

      final keys1 = await x3dhToSessionKeys(sharedSecret);
      final keys2 = await x3dhToSessionKeys(sharedSecret);

      final r1 = await keys1.rootKey.extractBytes();
      final r2 = await keys2.rootKey.extractBytes();
      expect(r1, equals(r2));
    });
  });
}

List<int> _hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}
