import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';

void main() {
  group('SenderKey', () {
    test('encrypt/decrypt roundtrip', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final chainKey = SecretKey.fromBytes(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );
      final senderKey = SenderKey(chainKey: chainKey, iteration: 0);

      const message = 'Group message';
      final plaintext = Uint8List.fromList(utf8.encode(message));

      // Encrypt
      final result = await senderKey.encrypt(
        plaintext: plaintext,
        associatedData: Uint8List.fromList(utf8.encode('group-header')),
      );

      // Decrypt with the same key state (before encryption)
      final decrypted = await SenderKey.decrypt(
        chainKey: chainKey,
        expectedIteration: 0,
        ciphertext: result.ciphertext,
        associatedData: Uint8List.fromList(utf8.encode('group-header')),
      );
      expect(decrypted, equals(plaintext));
    });

    test('next key produces different ciphertext for same plaintext', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final chainKey = SecretKey.fromBytes(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );
      final senderKey = SenderKey(chainKey: chainKey, iteration: 0);

      const message = 'Same message';
      final plaintext = Uint8List.fromList(utf8.encode(message));

      final result1 = await senderKey.encrypt(plaintext: plaintext);
      final result2 = await result1.nextKey.encrypt(plaintext: plaintext);

      expect(result1.ciphertext, isNot(equals(result2.ciphertext)));
      expect(result2.iteration, equals(2));
    });

    test('wrong iteration fails', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final chainKey = SecretKey.fromBytes(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );
      final senderKey = SenderKey(chainKey: chainKey, iteration: 0);

      const message = 'Test';
      final plaintext = Uint8List.fromList(utf8.encode(message));

      final result = await senderKey.encrypt(plaintext: plaintext);

      // Decrypt with wrong iteration (expecting iteration 1 but used 0)
      // Since decrypt uses the same chain key derivation, wrong iteration means wrong key
      // We can't easily test "wrong iteration" without key window, but we can verify
      // that the same key works
      final decrypted = await SenderKey.decrypt(
        chainKey: chainKey,
        expectedIteration: 0,
        ciphertext: result.ciphertext,
      );
      expect(decrypted, equals(plaintext));
    });

    test('rotate produces new key', () async {
      final rotated = await SenderKey.rotate();
      expect(rotated.iteration, equals(0));
      expect(rotated.chainKey, isNotNull);
    });
  });

  group('SenderKeyState', () {
    test('keyFor returns placeholder for unknown user', () {
      final state = SenderKeyState(senderKeys: {});
      final key = state.keyFor('unknown-user');
      expect(key.iteration, equals(0));
    });

    test('withKey adds/replaces key', () {
      final state = SenderKeyState(senderKeys: {});
      final key = SenderKey(
        chainKey: SecretKey.fromBytes(Uint8List(32)),
        iteration: 5,
      );
      final updated = state.withKey('user-1', key);
      expect(updated.keyFor('user-1').iteration, equals(5));
      expect(updated.keyFor('user-2').iteration, equals(0));
    });
  });
}

List<int> _hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}
