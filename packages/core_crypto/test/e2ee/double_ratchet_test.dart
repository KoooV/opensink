import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';

void main() {
  group('DoubleRatchet', () {
    test('encrypt/decrypt roundtrip between two parties', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      // Alice sends to Bob: both use the same initial chain keys
      final alice = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
      );

      final bob = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.receivingChainKey,
        receivingChainKey: sessionKeys.sendingChainKey,
      );

      const message = 'Hello Bob!';
      final plaintext = Uint8List.fromList(utf8.encode(message));
      final aad = Uint8List.fromList(utf8.encode('header'));

      // Alice encrypts
      final aliceResult = await alice.encrypt(
        plaintext: plaintext,
        associatedData: aad,
      );
      expect(aliceResult.ciphertext, isNotEmpty);

      // Bob decrypts using his receiving chain key (which matches Alice's sending chain key)
      final bobResult = await bob.decrypt(
        ciphertext: aliceResult.ciphertext,
        associatedData: aad,
      );
      expect(bobResult.ciphertext, equals(plaintext));
    });

    test('tampered ciphertext fails decryption', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final alice = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
      );

      final bob = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.receivingChainKey,
        receivingChainKey: sessionKeys.sendingChainKey,
      );

      const message = 'Test';
      final plaintext = Uint8List.fromList(utf8.encode(message));

      final aliceResult = await alice.encrypt(plaintext: plaintext);
      final tampered = Uint8List.fromList(aliceResult.ciphertext);
      tampered[tampered.length - 1] ^= 0xff;

      // Bob's decrypt should throw DecryptionFailed (caught as StateError from unwrap)
      expect(
        () => bob.decrypt(ciphertext: tampered),
        throwsA(isA<StateError>()),
      );
    });
  });
}

List<int> _hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}
