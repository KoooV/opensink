import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';

void main() {
  group('DoubleRatchet', () {
    test('encrypt/decrypt roundtrip between two parties', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey.fromBytes(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      // Alice sends to Bob: Alice uses sendingChainKey, Bob uses receivingChainKey for decryption
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
      final aliceResult = alice.encrypt(plaintext: plaintext, associatedData: aad);
      expect(aliceResult.ciphertext, isNotEmpty);

      // Bob decrypts using his receiving chain key (which matches Alice's sending chain key)
      // Note: Bob's DoubleRatchet is initialized with the same keys but his "receivingChainKey"
      // is actually Alice's "sendingChainKey"
      final bobResult = bob.decrypt(ciphertext: aliceResult.ciphertext, associatedData: aad);
      expect(bobResult.ciphertext, equals(plaintext));

      // Bob replies
      const reply = 'Hi Alice!';
      final replyPlaintext = Uint8List.fromList(utf8.encode(reply));
      final bobReply = bob.encrypt(plaintext: replyPlaintext, associatedData: aad);

      // Alice decrypts Bob's reply
      final aliceNext = aliceResult.nextState;
      final aliceDecryptReply = aliceNext.decrypt(
        ciphertext: bobReply.ciphertext,
        associatedData: aad,
      );
      expect(aliceDecryptReply.ciphertext, equals(replyPlaintext));
    });

    test('tampered ciphertext fails decryption', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey.fromBytes(
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

      final aliceResult = alice.encrypt(plaintext: plaintext);
      final tampered = Uint8List.fromList(aliceResult.ciphertext);
      tampered[tampered.length - 1] ^= 0xff;

      // Bob's decrypt should fail
      // Note: DoubleRatchet.decrypt returns DoubleRatchetResult, not CryptoResult.
      // If decryption fails, it throws an exception from aead.decrypt.
      // We expect an exception.
      expect(
        () => bob.decrypt(ciphertext: tampered),
        throwsA(isA<Error>()),
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
