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
  group('SenderKey roundtrip', () {
    test('encrypt/decrypt roundtrip with signing', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final chainKey = SecretKey(hexToUint8List(secretHex));
      final signingPair = await Ed25519().newKeyPair();
      final signingPub = await signingPair.extractPublicKey();

      final senderKey = SenderKey(
        chainKey: chainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );

      const message = 'Group message';
      final plaintext = Uint8List.fromList(message.codeUnits);

      final encResult = await senderKey.encrypt(plaintext: plaintext);
      expect(encResult.isOk, isTrue);
      final enc = (encResult as Ok<SenderKeyResult, CryptoError>).value;

      final decResult = await SenderKey.decrypt(
        chainKey: chainKey,
        signingPublicKey: signingPub,
        expectedIteration: 0,
        ciphertext: enc.ciphertext,
        signature: enc.signature,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(decResult.isOk, isTrue);
      expect(bytesToHex((decResult as Ok).value),
          bytesToHex(plaintext));
    });

    test('iteration advances after encrypt', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final chainKey = SecretKey(hexToUint8List(secretHex));
      final signingPair = await Ed25519().newKeyPair();

      final senderKey = SenderKey(
        chainKey: chainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );

      expect(senderKey.sequenceNumber, equals(0));

      final enc1 = await senderKey.encrypt(
        plaintext: Uint8List.fromList('first'.codeUnits),
      );
      expect(enc1.isOk, isTrue);
      expect((enc1 as Ok).value.iteration, equals(0));
      expect((enc1 as Ok).value.nextKey.sequenceNumber, equals(1));

      final enc2 = await (enc1 as Ok).value.nextKey.encrypt(
        plaintext: Uint8List.fromList('second'.codeUnits),
      );
      expect(enc2.isOk, isTrue);
      expect((enc2 as Ok).value.iteration, equals(1));
    });

    test('wrong iteration → decryption fails', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final chainKey = SecretKey(hexToUint8List(secretHex));
      final signingPair = await Ed25519().newKeyPair();
      final signingPub = await signingPair.extractPublicKey();

      final senderKey = SenderKey(
        chainKey: chainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );

      final encResult = await senderKey.encrypt(
        plaintext: Uint8List.fromList('test'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final enc = (encResult as Ok).value;

      // Decrypt with wrong iteration (1 instead of 0).
      final decResult = await SenderKey.decrypt(
        chainKey: chainKey,
        signingPublicKey: signingPub,
        expectedIteration: 1,
        ciphertext: enc.ciphertext,
        signature: enc.signature,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(decResult.isErr, isTrue);
    });

    test('tampered signature → InvalidSignature', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final chainKey = SecretKey(hexToUint8List(secretHex));
      final signingPair = await Ed25519().newKeyPair();
      final signingPub = await signingPair.extractPublicKey();

      final senderKey = SenderKey(
        chainKey: chainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );

      final encResult = await senderKey.encrypt(
        plaintext: Uint8List.fromList('signed'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final enc = (encResult as Ok).value;

      // Flip a byte in the signature.
      final tamperedSig = Uint8List.fromList(enc.signature);
      tamperedSig[0] ^= 0xFF;

      final decResult = await SenderKey.decrypt(
        chainKey: chainKey,
        signingPublicKey: signingPub,
        expectedIteration: 0,
        ciphertext: enc.ciphertext,
        signature: tamperedSig,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(decResult.isErr, isTrue);
      expect(decResult.unwrapErr(), isA<InvalidSignature>());
    });

    test('tampered ciphertext → signature invalid (signature covers ciphertext)', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final chainKey = SecretKey(hexToUint8List(secretHex));
      final signingPair = await Ed25519().newKeyPair();
      final signingPub = await signingPair.extractPublicKey();

      final senderKey = SenderKey(
        chainKey: chainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );

      final encResult = await senderKey.encrypt(
        plaintext: Uint8List.fromList('tamper me'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final enc = (encResult as Ok).value;

      // Flip a byte in ciphertext — signature no longer matches.
      final tampered = Uint8List.fromList(enc.ciphertext);
      tampered[tampered.length - 1] ^= 0xFF;

      final decResult = await SenderKey.decrypt(
        chainKey: chainKey,
        signingPublicKey: signingPub,
        expectedIteration: 0,
        ciphertext: tampered,
        signature: enc.signature,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(decResult.isErr, isTrue);
      expect(decResult.unwrapErr(), isA<InvalidSignature>());
    });

    test('wrong chain key → DecryptionFailed (valid signature, wrong key)', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      const wrongHex = 'ffeeddccbbaa99887766554433221100'
          '00112233445566778899aabbccddeeff';
      final chainKey = SecretKey(hexToUint8List(secretHex));
      final wrongChainKey = SecretKey(hexToUint8List(wrongHex));
      final signingPair = await Ed25519().newKeyPair();
      final signingPub = await signingPair.extractPublicKey();

      final senderKey = SenderKey(
        chainKey: chainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );

      final encResult = await senderKey.encrypt(
        plaintext: Uint8List.fromList('test'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final enc = (encResult as Ok).value;

      // Decrypt with wrong chain key — signature valid, AEAD fails.
      final decResult = await SenderKey.decrypt(
        chainKey: wrongChainKey,
        signingPublicKey: signingPub,
        expectedIteration: 0,
        ciphertext: enc.ciphertext,
        signature: enc.signature,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(decResult.isErr, isTrue);
      expect(decResult.unwrapErr(), isA<DecryptionFailed>());
    });
  });

  group('SenderKey rotate', () {
    test('rotate produces new key with iteration 0', () async {
      final rotated = await SenderKey.rotate(
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(rotated.sequenceNumber, equals(0));
      expect(rotated.groupId, equals('group-1'));
      expect(rotated.senderPeerId, equals('alice'));
    });

    test('old key cannot decrypt message encrypted by rotated key', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      const secretHex2 = 'ffeeddccbbaa99887766554433221100'
          '00112233445566778899aabbccddeeff';
      final oldChainKey = SecretKey(hexToUint8List(secretHex));
      final newChainKey = SecretKey(hexToUint8List(secretHex2));
      final signingPair = await Ed25519().newKeyPair();
      final signingPub = await signingPair.extractPublicKey();

      // Old key encrypts message at iteration 0.
      final oldKey = SenderKey(
        chainKey: oldChainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      final encResult = await oldKey.encrypt(
        plaintext: Uint8List.fromList('old message'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final enc = (encResult as Ok).value;

      // New key (different chain key) tries to decrypt old message → fails.
      final decResult = await SenderKey.decrypt(
        chainKey: newChainKey,
        signingPublicKey: signingPub,
        expectedIteration: 0,
        ciphertext: enc.ciphertext,
        signature: enc.signature,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(decResult.isErr, isTrue);
    });

    test('new participant cannot read past messages', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final chainKey = SecretKey(hexToUint8List(secretHex));
      final signingPair = await Ed25519().newKeyPair();
      final signingPub = await signingPair.extractPublicKey();

      final senderKey = SenderKey(
        chainKey: chainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );

      // Encrypt message at iteration 0.
      final enc0 = await senderKey.encrypt(
        plaintext: Uint8List.fromList('message 0'.codeUnits),
      );
      expect(enc0.isOk, isTrue);

      // Advance key to iteration 5.
      var currentKey = (enc0 as Ok).value.nextKey;
      for (var i = 1; i < 5; i++) {
        final enc = await currentKey.encrypt(
          plaintext: Uint8List.fromList('message $i'.codeUnits),
        );
        expect(enc.isOk, isTrue);
        currentKey = (enc as Ok).value.nextKey;
      }

      // New participant starts at iteration 5 — cannot decrypt message 0.
      final decResult = await SenderKey.decrypt(
        chainKey: currentKey.chainKey,
        signingPublicKey: signingPub,
        expectedIteration: 0,
        ciphertext: (enc0 as Ok).value.ciphertext,
        signature: (enc0 as Ok).value.signature,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(decResult.isErr, isTrue);
    });
  });

  group('SenderKeyState replay protection', () {
    test('acceptSequence accepts new sequence and rejects replay', () {
      final state = SenderKeyState(senderKeys: {});

      final result1 = state.acceptSequence('alice', 1);
      expect(result1.accepted, isTrue);

      final result2 = result1.state.acceptSequence('alice', 1);
      expect(result2.accepted, isFalse); // replay

      final result3 = result2.state.acceptSequence('alice', 0);
      expect(result3.accepted, isFalse); // too old

      final result4 = result3.state.acceptSequence('alice', 2);
      expect(result4.accepted, isTrue); // new, accepted
    });

    test('acceptSequence rejects sequence too far behind', () {
      final state = SenderKeyState(senderKeys: {});

      // Accept sequence 100.
      final r1 = state.acceptSequence('alice', 100);
      expect(r1.accepted, isTrue);

      // Sequence 50 is too far behind.
      final r2 = r1.state.acceptSequence('alice', 50);
      expect(r2.accepted, isFalse);
    });
  });

  group('SenderKeyState key management', () {
    test('keyFor returns placeholder for unknown sender', () {
      final state = SenderKeyState(senderKeys: {});
      final key = state.keyFor('unknown');
      expect(key.sequenceNumber, equals(0));
      expect(key.groupId, isEmpty);
    });

    test('withKey adds/replaces key', () {
      final state = SenderKeyState(senderKeys: {});
      final key = SenderKey(
        chainKey: SecretKey(Uint8List(32)),
        signingKeyPair: SimpleKeyPairData(
          Uint8List(32),
          publicKey: SimplePublicKey(
            Uint8List(32),
            type: KeyPairType.ed25519,
          ),
          type: KeyPairType.ed25519,
        ),
        sequenceNumber: 5,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      final updated = state.withKey('alice', key);
      expect(updated.keyFor('alice').sequenceNumber, equals(5));
      expect(updated.keyFor('bob').sequenceNumber, equals(0));
    });
  });

  // -------------------------------------------------------------------------
  // F2 correctness tests: Sender Keys
  // -------------------------------------------------------------------------

  group('SenderKey F2: atomicity', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    test('signature verified before decryption; error does not move chain', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final chainKey = SecretKey(hexToUint8List(secretHex));
      final signingPair = await Ed25519().newKeyPair();
      final signingPub = await signingPair.extractPublicKey();

      final senderKey = SenderKey(
        chainKey: chainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );

      final encResult = await senderKey.encrypt(
        plaintext: Uint8List.fromList('atomic-sender'.codeUnits),
      );
      expect(encResult.isOk, isTrue, reason: 'seed=$seed');
      final enc = (encResult as Ok).value;

      // Chain key before failed decrypt (same key, decrypt is static so no state change).
      final chainBytesBefore = Uint8List.fromList(await chainKey.extractBytes());

      // Tamper signature → error, no state change.
      final tamperedSig = Uint8List.fromList(enc.signature);
      tamperedSig[0] ^= 0xFF;

      final badResult = await SenderKey.decrypt(
        chainKey: chainKey,
        signingPublicKey: signingPub,
        expectedIteration: 0,
        ciphertext: enc.ciphertext,
        signature: tamperedSig,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(badResult.isErr, isTrue, reason: 'seed=$seed');
      expect(badResult.unwrapErr(), isA<InvalidSignature>());

      // Chain key unchanged (decrypt is static, doesn't mutate).
      final chainBytesAfter = Uint8List.fromList(await chainKey.extractBytes());
      expect(bytesToHex(chainBytesAfter), bytesToHex(chainBytesBefore));

      // Next valid message with same chain key decrypts.
      final okResult = await SenderKey.decrypt(
        chainKey: chainKey,
        signingPublicKey: signingPub,
        expectedIteration: 0,
        ciphertext: enc.ciphertext,
        signature: enc.signature,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(okResult.isOk, isTrue, reason: 'seed=$seed');
      expect(bytesToHex((okResult as Ok).value),
          bytesToHex('atomic-sender'.codeUnits));
    });

    test('tampered ciphertext → signature invalid (signature covers ciphertext)', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final chainKey = SecretKey(hexToUint8List(secretHex));
      final signingPair = await Ed25519().newKeyPair();
      final signingPub = await signingPair.extractPublicKey();

      final senderKey = SenderKey(
        chainKey: chainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );

      final encResult = await senderKey.encrypt(
        plaintext: Uint8List.fromList('tamper-ct'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final enc = (encResult as Ok).value;

      // Flip a byte in ciphertext → signature no longer matches.
      final tampered = Uint8List.fromList(enc.ciphertext);
      tampered[tampered.length - 1] ^= 0xFF;

      final result = await SenderKey.decrypt(
        chainKey: chainKey,
        signingPublicKey: signingPub,
        expectedIteration: 0,
        ciphertext: tampered,
        signature: enc.signature,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(result.isErr, isTrue, reason: 'seed=$seed');
      expect(result.unwrapErr(), isA<InvalidSignature>());
    });

    test('tampered header (groupId/senderPeerId/seq) → signature invalid', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final chainKey = SecretKey(hexToUint8List(secretHex));
      final signingPair = await Ed25519().newKeyPair();
      final signingPub = await signingPair.extractPublicKey();

      final senderKey = SenderKey(
        chainKey: chainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );

      final encResult = await senderKey.encrypt(
        plaintext: Uint8List.fromList('auth-hdr'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final enc = (encResult as Ok).value;

      // Decrypt with wrong groupId → header differs → signature invalid.
      final result = await SenderKey.decrypt(
        chainKey: chainKey,
        signingPublicKey: signingPub,
        expectedIteration: 0,
        ciphertext: enc.ciphertext,
        signature: enc.signature,
        groupId: 'wrong-group',
        senderPeerId: 'alice',
      );
      expect(result.isErr, isTrue, reason: 'seed=$seed');
      expect(result.unwrapErr(), isA<InvalidSignature>());
    });
  });

  group('SenderKey F2: DoS protection', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    test('huge sequenceNumber (2^31) rejected before computations', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final chainKey = SecretKey(hexToUint8List(secretHex));
      final signingPair = await Ed25519().newKeyPair();
      final signingPub = await signingPair.extractPublicKey();

      final senderKey = SenderKey(
        chainKey: chainKey,
        signingKeyPair: signingPair,
        sequenceNumber: 0,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );

      final encResult = await senderKey.encrypt(
        plaintext: Uint8List.fromList('dos-seq'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final enc = (encResult as Ok).value;

      // Decrypt with huge expectedIteration (2^31). Signature was made over header
      // with seq=0, so header with seq=2^31 won't match → InvalidSignature.
      // This must happen before any HKDF/AEAD computation.
      const hugeIter = 1 << 31;
      final result = await SenderKey.decrypt(
        chainKey: chainKey,
        signingPublicKey: signingPub,
        expectedIteration: hugeIter,
        ciphertext: enc.ciphertext,
        signature: enc.signature,
        groupId: 'group-1',
        senderPeerId: 'alice',
      );
      expect(result.isErr, isTrue, reason: 'seed=$seed');
      expect(result.unwrapErr(), isA<InvalidSignature>());
    });

    test('SenderKeyState replay window bounded by memory (max 100 per sender)', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      var state = SenderKeyState(senderKeys: {});

      // Accept sequences 0..101 for 'alice', chaining the state.
      for (var i = 0; i <= 101; i++) {
        final r = state.acceptSequence('alice', i);
        expect(r.accepted, isTrue, reason: 'seq $i seed=$seed');
        state = r.state;
      }

      // Window should be bounded at 100.
      final accepted = state.acceptedSequences['alice'] ?? <int>{};
      expect(accepted.length, lessThanOrEqualTo(100), reason: 'seed=$seed');

      // Replay of accepted sequence → rejected.
      final replay = state.acceptSequence('alice', 50);
      expect(replay.accepted, isFalse, reason: 'seed=$seed');

      // Sequence too far behind → rejected (0 <= lastAcceptedSequence=101).
      final tooOld = state.acceptSequence('alice', 0);
      expect(tooOld.accepted, isFalse, reason: 'seed=$seed');
    });

    test('different senders have independent replay windows', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final state = SenderKeyState(senderKeys: {});

      final r1 = state.acceptSequence('alice', 5);
      expect(r1.accepted, isTrue);

      final r2 = r1.state.acceptSequence('bob', 5);
      expect(r2.accepted, isTrue, reason: 'different sender, same seq should be accepted seed=$seed');

      // Replay for alice.
      final r3 = r2.state.acceptSequence('alice', 5);
      expect(r3.accepted, isFalse, reason: 'seed=$seed');
    });
  });
}
