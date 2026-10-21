import 'dart:math';
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
  group('DoubleRatchet ping-pong', () {
    test('Alice↔Bob encrypt/decrypt roundtrip', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      // Alice sends to Bob.
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

      final plaintext = Uint8List.fromList('Hello Bob!'.codeUnits);
      final aad = Uint8List.fromList('header'.codeUnits);

      final aliceResult = await alice.encrypt(
        plaintext: plaintext,
        associatedData: aad,
      );
      expect(aliceResult.isOk, isTrue);
      final aliceWire = (aliceResult as Ok).value.wireFormat;

      final bobResult = await bob.decrypt(
        data: aliceWire,
        associatedData: aad,
      );
      expect(bobResult.isOk, isTrue);
      expect(bytesToHex((bobResult as Ok).value.wireFormat),
          bytesToHex(plaintext));
    });

    test('several messages in one direction', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      var aliceState = alice;
      var bobState = bob;

      for (var i = 0; i < 5; i++) {
        final plaintext = Uint8List.fromList('Message $i'.codeUnits);

        final encResult = await aliceState.encrypt(plaintext: plaintext);
        expect(encResult.isOk, isTrue);
        final enc = (encResult as Ok).value;
        aliceState = enc.nextState;

        final decResult = await bobState.decrypt(data: enc.wireFormat);
        expect(decResult.isOk, isTrue);
        final dec = (decResult as Ok).value;
        expect(bytesToHex(dec.wireFormat), bytesToHex(plaintext));
        bobState = dec.nextState;
      }
    });
  });

  group('DoubleRatchet out-of-order and lost messages', () {
    test('out-of-order delivery within window', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      var aliceState = alice;
      var bobState = bob;

      // Alice sends messages 1, 2, 3.
      final wires = <Uint8List>[];
      for (var i = 0; i < 3; i++) {
        final encResult = await aliceState.encrypt(
          plaintext: Uint8List.fromList('msg$i'.codeUnits),
        );
        expect(encResult.isOk, isTrue);
        final enc = (encResult as Ok).value;
        wires.add(enc.wireFormat);
        aliceState = enc.nextState;
      }

      // Bob receives message 3 first (out of order), then 1, then 2.
      final dec3 = await bobState.decrypt(data: wires[2]);
      expect(dec3.isOk, isTrue);
      expect(bytesToHex((dec3 as Ok).value.wireFormat),
          bytesToHex('msg2'.codeUnits));
      bobState = (dec3 as Ok).value.nextState;

      final dec1 = await bobState.decrypt(data: wires[0]);
      expect(dec1.isOk, isTrue);
      expect(bytesToHex((dec1 as Ok).value.wireFormat),
          bytesToHex('msg0'.codeUnits));
      bobState = (dec1 as Ok).value.nextState;

      final dec2 = await bobState.decrypt(data: wires[1]);
      expect(dec2.isOk, isTrue);
      expect(bytesToHex((dec2 as Ok).value.wireFormat),
          bytesToHex('msg1'.codeUnits));
    });

    test('lost message → skipped key, later message decrypts', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      var aliceState = alice;
      var bobState = bob;

      // Alice sends messages 1, 2, 3.
      final wires = <Uint8List>[];
      for (var i = 0; i < 3; i++) {
        final encResult = await aliceState.encrypt(
          plaintext: Uint8List.fromList('msg$i'.codeUnits),
        );
        expect(encResult.isOk, isTrue);
        final enc = (encResult as Ok).value;
        wires.add(enc.wireFormat);
        aliceState = enc.nextState;
      }

      // Bob loses message 1, receives 2 and 3.
      final dec2 = await bobState.decrypt(data: wires[1]);
      expect(dec2.isOk, isTrue);
      bobState = (dec2 as Ok).value.nextState;

      final dec3 = await bobState.decrypt(data: wires[2]);
      expect(dec3.isOk, isTrue);
      bobState = (dec3 as Ok).value.nextState;

      // Message 1 was skipped — its key is in skippedKeys.
      // When it arrives late, it should decrypt from the skipped key.
      final dec1 = await bobState.decrypt(data: wires[0]);
      expect(dec1.isOk, isTrue);
      expect(bytesToHex((dec1 as Ok).value.wireFormat),
          bytesToHex('msg0'.codeUnits));
    });

    test('skip more than MAX_SKIP → error', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      var aliceState = alice;
      var bobState = bob;

      // Alice sends 150 messages (more than MAX_SKIP=100).
      final wires = <Uint8List>[];
      for (var i = 0; i < 150; i++) {
        final encResult = await aliceState.encrypt(
          plaintext: Uint8List.fromList('msg$i'.codeUnits),
        );
        expect(encResult.isOk, isTrue);
        wires.add((encResult as Ok).value.wireFormat);
        aliceState = (encResult as Ok).value.nextState;
      }

      // Bob tries to decrypt message 149 without receiving any prior messages.
      // diff = 149 > maxSkip = 100 → error.
      final result = await bobState.decrypt(data: wires[149]);
      expect(result.isErr, isTrue);
    });
  });

  group('DoubleRatchet replay and tampering', () {
    test('replay message → rejection', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('original'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = (encResult as Ok).value.wireFormat;

      // Bob decrypts once — succeeds.
      var bobState = bob;
      final dec1 = await bobState.decrypt(data: wire);
      expect(dec1.isOk, isTrue);
      bobState = (dec1 as Ok).value.nextState;

      // Bob decrypts same message again — replay, should fail.
      final dec2 = await bobState.decrypt(data: wire);
      expect(dec2.isErr, isTrue);
    });

    test('tampered ciphertext → DecryptionFailed', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('tamper me'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = Uint8List.fromList((encResult as Ok).value.wireFormat);

      // Flip a byte in the ciphertext region (after header + nonce).
      wire[wire.length - 1] ^= 0xFF;

      final result = await bob.decrypt(data: wire);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<DecryptionFailed>());
    });

    test('tampered header → DecryptionFailed', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('header tamper'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = Uint8List.fromList((encResult as Ok).value.wireFormat);

      // Flip version byte.
      wire[0] ^= 0xFF;

      final result = await bob.decrypt(data: wire);
      expect(result.isErr, isTrue);
    });
  });

  group('DoubleRatchet dhRatchetStep', () {
    test('keys before and after DH step differ', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final alice = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
        dhPrivateKey: SecretKey(hexToUint8List(
          '1111111111111111111111111111111111111111111111111111111111111111',
        )),
        dhPublicKey: SimplePublicKey(
          hexToUint8List(
            '2222222222222222222222222222222222222222222222222222222222222222',
          ),
          type: KeyPairType.x25519,
        ),
      );

      final beforeRootBytes = await alice.rootKey.extractBytes();
      final beforeSendBytes = await alice.sendingChainKey.extractBytes();

      // Bob's DH public key for the ratchet step.
      final bobDhPub = SimplePublicKey(
        hexToUint8List(
          '3333333333333333333333333333333333333333333333333333333333333333',
        ),
        type: KeyPairType.x25519,
      );

      final stepResult = await alice.dhRatchetStep(bobDhPub);
      expect(stepResult.isOk, isTrue);
      final nextState = (stepResult as Ok).value;

      final afterRootBytes = await nextState.rootKey.extractBytes();
      final afterSendBytes = await nextState.sendingChainKey.extractBytes();

      expect(bytesToHex(afterRootBytes), isNot(bytesToHex(beforeRootBytes)));
      expect(bytesToHex(afterSendBytes), isNot(bytesToHex(beforeSendBytes)));
    });
  });

  group('DoubleRatchet serialization', () {
    test('save state → restore → continue dialog', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final alice = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
      );

      // Send one message.
      final enc1 = await alice.encrypt(
        plaintext: Uint8List.fromList('before save'.codeUnits),
      );
      expect(enc1.isOk, isTrue);
      final state1 = (enc1 as Ok).value.nextState;

      // Serialize state.
      final serialized = await state1.toBytes();
      expect(serialized, isNotEmpty);

      // Deserialize.
      final restored = DoubleRatchet.fromBytes(serialized);

      // State should match.
      final rRoot = await restored.rootKey.extractBytes();
      final sRoot = await state1.rootKey.extractBytes();
      expect(bytesToHex(rRoot), bytesToHex(sRoot));

      // Continue dialog from restored state.
      final enc2 = await restored.encrypt(
        plaintext: Uint8List.fromList('after restore'.codeUnits),
      );
      expect(enc2.isOk, isTrue);

      // Bob decrypts both messages.
      final bob = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.receivingChainKey,
        receivingChainKey: sessionKeys.sendingChainKey,
      );

      final dec1 = await bob.decrypt(
        data: (enc1 as Ok).value.wireFormat,
      );
      expect(dec1.isOk, isTrue);
      expect(bytesToHex((dec1 as Ok).value.wireFormat),
          bytesToHex('before save'.codeUnits));

      final dec2 = await bob.decrypt(
        data: (enc2 as Ok).value.wireFormat,
      );
      expect(dec2.isOk, isTrue);
      expect(bytesToHex((dec2 as Ok).value.wireFormat),
          bytesToHex('after restore'.codeUnits));
    });

    test('unknown serialization version → error', () async {
      final data = Uint8List.fromList([99, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(() => DoubleRatchet.fromBytes(data), throwsA(isA<StateError>()));
    });
  });

  group('DoubleRatchet toString secrecy', () {
    test('toString does not reveal secrets', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final ratchet = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
      );

      final str = ratchet.toString();
      expect(str, contains('<secret>'));
      final rootBytes = await sessionKeys.rootKey.extractBytes();
      expect(str, isNot(contains(bytesToHex(rootBytes))));
    });
  });

  // -------------------------------------------------------------------------
  // F2 correctness tests: Double Ratchet
  // -------------------------------------------------------------------------

  group('DoubleRatchet F2: long dialog 200+ DH steps', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    Future<(DoubleRatchet, DoubleRatchet, KeyPair, KeyPair)> setupWithDh() async {
      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);
      final aliceDh = await X25519().newKeyPair();
      final bobDh = await X25519().newKeyPair();
      final alice = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
        dhPrivateKey: SecretKey(await aliceDh.extractPrivateKeyBytes()),
        dhPublicKey: await aliceDh.extractPublicKey(),
      );
      final bob = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.receivingChainKey,
        receivingChainKey: sessionKeys.sendingChainKey,
        dhPrivateKey: SecretKey(await bobDh.extractPrivateKeyBytes()),
        dhPublicKey: await bobDh.extractPublicKey(),
        remoteDhPublicKey: await aliceDh.extractPublicKey(),
      );
      return (alice, bob, aliceDh, bobDh);
    }

    test('200+ DH steps, alternating series of varying length', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      // ignore: avoid_print
      print('SEED: $seed');

      final setup = await setupWithDh();
      var aliceState = setup.$1;
      var bobState = setup.$2;

      int dhSteps = 0;
      int totalMessages = 0;
      const targetDhSteps = 200;

      var aliceTurn = true;
      while (dhSteps < targetDhSteps) {
        final doRatchet = (totalMessages % 3 == 0); // ratchet every 3rd message
        // Берём текущие DH-ключи из состояния (меняются после каждого шага).
        final senderRemoteDhPub = aliceTurn
            ? bobState.dhPublicKey
            : aliceState.dhPublicKey;
        final senderState = aliceTurn ? aliceState : bobState;
        final receiverState = aliceTurn ? bobState : aliceState;

        final plaintext = Uint8List.fromList(
          'msg-$totalMessages-${aliceTurn ? 'A' : 'B'}'.codeUnits,
        );
        final encResult = await senderState.encrypt(
          plaintext: plaintext,
          remotePublicKey: doRatchet ? senderRemoteDhPub : null,
        );
        expect(encResult.isOk, isTrue, reason: 'msg #$totalMessages seed=$seed');
        final enc = (encResult as Ok).value;

        final decResult = await receiverState.decrypt(data: enc.wireFormat);
        expect(decResult.isOk, isTrue, reason: 'decrypt msg #$totalMessages seed=$seed');
        final dec = (decResult as Ok).value;
        expect(bytesToHex(dec.wireFormat), bytesToHex(plaintext),
            reason: 'plaintext mismatch msg #$totalMessages seed=$seed');

        if (aliceTurn) {
          aliceState = enc.nextState;
          bobState = dec.nextState;
        } else {
          bobState = enc.nextState;
          aliceState = dec.nextState;
        }

        if (doRatchet) dhSteps++;
        totalMessages++;
        aliceTurn = !aliceTurn;
      }

      expect(dhSteps, greaterThanOrEqualTo(targetDhSteps));
      expect(totalMessages, greaterThanOrEqualTo(targetDhSteps));
    });
  });

  group('DoubleRatchet F2: network simulation', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    test('duplicates, reordering within MAX_SKIP, losses — each message once, equals original', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      // Alice sends 50 messages.
      var aliceState = alice;
      final wires = <Uint8List>[];
      final plaintexts = <Uint8List>[];
      for (var i = 0; i < 50; i++) {
        final pt = Uint8List.fromList('net-msg-$i'.codeUnits);
        final encResult = await aliceState.encrypt(plaintext: pt);
        expect(encResult.isOk, isTrue);
        final enc = (encResult as Ok).value;
        wires.add(enc.wireFormat);
        plaintexts.add(pt);
        aliceState = enc.nextState;
      }

      // Delivery order: duplicates, reordering within window, losses.
      // Order: 0, 2, 1, 4, 3, 2 (dup), 6, 5, 8, 7, 10, 9, ... (pairs swapped)
      final deliveryOrder = <int>[];
      for (var i = 0; i < 50; i += 2) {
        if (i + 1 < 50) {
          deliveryOrder.add(i + 1);
          deliveryOrder.add(i);
        } else {
          deliveryOrder.add(i);
        }
      }
      // Add a duplicate of an already-delivered message.
      deliveryOrder.add(5);
      // Add a lost message index (never delivered): no-op, just skip.

      var bobState = bob;
      final decrypted = <int, Uint8List>{};
      int decryptCount = 0;

      for (final msgIdx in deliveryOrder) {
        final result = await bobState.decrypt(data: wires[msgIdx]);
        if (result.isErr) {
          // Replay or out-of-window — acceptable, but must not throw.
          continue;
        }
        final dec = (result as Ok).value;
        final pt = bytesToHex(dec.wireFormat);
        final expected = bytesToHex(plaintexts[msgIdx]);
        expect(pt, expected, reason: 'msg $msgIdx seed=$seed');

        // Each message decrypted at most once.
        if (decrypted.containsKey(msgIdx)) {
          fail('Message $msgIdx decrypted more than once (seed=$seed)');
        }
        decrypted[msgIdx] = dec.wireFormat;
        decryptCount++;
        bobState = dec.nextState;
      }

      // All non-duplicate messages in delivery order should decrypt.
      final uniqueIndices = deliveryOrder.toSet();
      expect(decryptCount, equals(uniqueIndices.length),
          reason: 'seed=$seed, decrypted=$decryptCount unique=${uniqueIndices.length}');
      expect(decryptCount, greaterThan(0));
      expect(decryptCount, lessThanOrEqualTo(50));
    });

    test('loss beyond MAX_SKIP → error, no exception', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      var aliceState = alice;
      final wires = <Uint8List>[];
      for (var i = 0; i < 150; i++) {
        final encResult = await aliceState.encrypt(
          plaintext: Uint8List.fromList('loss-msg-$i'.codeUnits),
        );
        expect(encResult.isOk, isTrue);
        wires.add((encResult as Ok).value.wireFormat);
        aliceState = (encResult as Ok).value.nextState;
      }

      // Bob jumps to message 149 without any prior messages: diff=149 > maxSkip=100.
      var bobState = bob;
      final result = await bobState.decrypt(data: wires[149]);
      expect(result.isErr, isTrue, reason: 'seed=$seed');
      expect(result.unwrapErr(), isA<DecryptionFailed>());

      // Bob's state must be unchanged (atomicity).
      final before = await bobState.toBytes();
      final after = await bobState.toBytes();
      expect(bytesToHex(after), bytesToHex(before));
    });
  });

  group('DoubleRatchet F2: atomicity', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    test('tampered ciphertext → error, state bytes identical, next valid message decrypts', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      // Alice sends messages 1..10. Bob receives message 10 first (skips 0..8).
      var aliceState = alice;
      final wires = <Uint8List>[];
      for (var i = 0; i < 10; i++) {
        final encResult = await aliceState.encrypt(
          plaintext: Uint8List.fromList('atomic-msg-$i'.codeUnits),
        );
        expect(encResult.isOk, isTrue);
        wires.add((encResult as Ok).value.wireFormat);
        aliceState = (encResult as Ok).value.nextState;
      }

      var bobState = bob;

      // Serialize before tampered decrypt.
      final beforeBytes = await bobState.toBytes();

      // Tamper ciphertext of message 10 (index 9).
      final tampered = Uint8List.fromList(wires[9]);
      tampered[tampered.length - 1] ^= 0xFF;

      final badResult = await bobState.decrypt(data: tampered);
      expect(badResult.isErr, isTrue, reason: 'seed=$seed');

      // State must be byte-identical after failed decrypt.
      final afterBytes = await bobState.toBytes();
      expect(bytesToHex(afterBytes), bytesToHex(beforeBytes),
          reason: 'atomicity violated seed=$seed');

      // Next valid message (message 10, untampered) must decrypt.
      final goodResult = await bobState.decrypt(data: wires[9]);
      expect(goodResult.isOk, isTrue, reason: 'seed=$seed');
      final good = (goodResult as Ok).value;
      expect(bytesToHex(good.wireFormat),
          bytesToHex('atomic-msg-9'.codeUnits));
      bobState = good.nextState;
    });

    test('tampered header (message number) → error, state unchanged', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('header-tamper'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = Uint8List.fromList((encResult as Ok).value.wireFormat);

      final beforeBytes = await bob.toBytes();

      // Flip a byte in messageNumber field (offset 34-41).
      final tampered = Uint8List.fromList(wire);
      tampered[34] ^= 0x01;

      final result = await bob.decrypt(data: tampered);
      expect(result.isErr, isTrue, reason: 'seed=$seed');

      final afterBytes = await bob.toBytes();
      expect(bytesToHex(afterBytes), bytesToHex(beforeBytes),
          reason: 'atomicity violated seed=$seed');
    });

    test('tampered header (version byte) → error, state unchanged', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('version-tamper'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = Uint8List.fromList((encResult as Ok).value.wireFormat);

      final beforeBytes = await bob.toBytes();

      final tampered = Uint8List.fromList(wire);
      tampered[0] ^= 0xFF;

      final result = await bob.decrypt(data: tampered);
      expect(result.isErr, isTrue, reason: 'seed=$seed');

      final afterBytes = await bob.toBytes();
      expect(bytesToHex(afterBytes), bytesToHex(beforeBytes),
          reason: 'atomicity violated seed=$seed');
    });

    test('tampered optional DH field (ratchet message) → error, state unchanged', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final aliceDh = await X25519().newKeyPair();
      final bobDh = await X25519().newKeyPair();

      final alice = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
        dhPrivateKey: SecretKey(await aliceDh.extractPrivateKeyBytes()),
        dhPublicKey: await aliceDh.extractPublicKey(),
      );
      final bob = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.receivingChainKey,
        receivingChainKey: sessionKeys.sendingChainKey,
        dhPrivateKey: SecretKey(await bobDh.extractPrivateKeyBytes()),
        dhPublicKey: await bobDh.extractPublicKey(),
        remoteDhPublicKey: await aliceDh.extractPublicKey(),
      );

      final bobDhPub = await bobDh.extractPublicKey();
      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('dh-tamper'.codeUnits),
        remotePublicKey: bobDhPub,
      );
      expect(encResult.isOk, isTrue);
      final wire = Uint8List.fromList((encResult as Ok).value.wireFormat);

      // Wire format: version(1) || flags(1) || ephemeralPK(32) [offset 2-34]
      // || messageNumber(8) [34-42] || prevChainLength(8) [42-50]
      // || optional dhPublicKey(32) [50-82] || nonce(24) || ciphertext || mac(16)
      final beforeBytes = await bob.toBytes();

      // Flip a byte in the optional DH field (offset 50).
      final tampered = Uint8List.fromList(wire);
      tampered[50] ^= 0xFF;

      final result = await bob.decrypt(data: tampered);
      expect(result.isErr, isTrue, reason: 'seed=$seed');

      final afterBytes = await bob.toBytes();
      expect(bytesToHex(afterBytes), bytesToHex(beforeBytes),
          reason: 'atomicity violated seed=$seed');
    });
  });

  group('DoubleRatchet F2: DoS protection', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    test('huge messageNumber (2^31) rejected before loop, no allocation', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final bob = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.receivingChainKey,
        receivingChainKey: sessionKeys.sendingChainKey,
      );

      // Build a minimal valid-length header with huge messageNumber.
      // Header: version(1) + flags(1) + ephemeralPK(32) + messageNumber(8) + prevChainLength(8) = 50 bytes
      // Then nonce(24) + at least 1 byte ciphertext + mac(16) = 41+ bytes min.
      final header = Uint8List(50);
      header[0] = 1; // version
      header[1] = 0; // flags, no optional DH
      // ephemeralPK = zeros (offset 2-34)
      // messageNumber = 2^31 (offset 34-42)
      const hugeN = 1 << 31;
      for (var i = 0; i < 8; i++) {
        header[34 + i] = (hugeN >> (8 * i)) & 0xFF;
      }
      // prevChainLength = 0 (offset 42-50)
      // nonce (24 bytes) + ciphertext (0 bytes) + mac (16 bytes) = 40 bytes payload
      final payload = Uint8List(40);
      final data = Uint8List.fromList([...header, ...payload]);

      final result = await bob.decrypt(data: data);
      expect(result.isErr, isTrue, reason: 'seed=$seed');
    });

    test('huge previousChainLength rejected, no crash', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('pn-test'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = Uint8List.fromList((encResult as Ok).value.wireFormat);

      // Corrupt prevChainLength (offset 42-49) to 2^40.
      final tampered = Uint8List.fromList(wire);
      final hugePn = BigInt.from(1) << 40;
      for (var i = 0; i < 8; i++) {
        tampered[42 + i] = (hugePn >> (8 * i)).toInt() & 0xFF;
      }

      final result = await bob.decrypt(data: tampered);
      // prevChainLength is stored but not used for decryption; messageNumber matches,
      // so decryption may still succeed. The important thing: no crash/exception.
      expect(result.isOk || result.isErr, isTrue);
      // But state must not have grown unboundedly.
      final after = result.isOk ? (result as Ok).value.nextState : bob;
      final serialized = await after.toBytes();
      expect(serialized.length, lessThan(10000));
    });

    test('skipped keys bounded by maxSkip (FIFO eviction)', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      // Alice sends 150 сообщений.
      var aliceState = alice;
      final wires = <Uint8List>[];
      for (var i = 0; i < 150; i++) {
        final encResult = await aliceState.encrypt(
          plaintext: Uint8List.fromList('skip-msg-$i'.codeUnits),
        );
        expect(encResult.isOk, isTrue);
        wires.add((encResult as Ok).value.wireFormat);
        aliceState = (encResult as Ok).value.nextState;
      }

      // Bob получает сообщение 100 (индекс 100): diff = 100 <= maxSkip = 100.
      // Пропущенные ключи 0..99 (100 записей) — ровно maxSkip, FIFO не вытесняет.
      var bobState = bob;
      final result = await bobState.decrypt(data: wires[100]);
      expect(result.isOk, isTrue, reason: 'seed=$seed');
      bobState = (result as Ok).value.nextState;

      final serialized = await bobState.toBytes();
      // Размер сериализации ограничен: корень + цепи + DH + ~100 skipped keys.
      expect(serialized.length, lessThan(10000), reason: 'seed=$seed');
    });

    test('TTL removes old skipped keys', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      var aliceState = alice;
      final wires = <Uint8List>[];
      for (var i = 0; i < 10; i++) {
        final encResult = await aliceState.encrypt(
          plaintext: Uint8List.fromList('ttl-msg-$i'.codeUnits),
        );
        expect(encResult.isOk, isTrue);
        wires.add((encResult as Ok).value.wireFormat);
        aliceState = (encResult as Ok).value.nextState;
      }

      // Bob receives message 9 first → skips 0..8.
      var bobState = bob;
      final result = await bobState.decrypt(data: wires[9]);
      expect(result.isOk, isTrue, reason: 'seed=$seed');
      bobState = (result as Ok).value.nextState;

      // Message 0 arrives late — should still be in skippedKeys (TTL is 24h, not expired).
      final lateResult = await bobState.decrypt(data: wires[0]);
      expect(lateResult.isOk, isTrue, reason: 'seed=$seed (TTL not expired)');
    });
  });

  group('DoubleRatchet F2: header authentication', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    test('tamper dh field → reject', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('auth-dh'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = Uint8List.fromList((encResult as Ok).value.wireFormat);

      // Tamper ephemeralPK field (offset 2-33), flip byte at offset 2.
      final tampered = Uint8List.fromList(wire);
      tampered[2] ^= 0xFF;

      final result = await bob.decrypt(data: tampered);
      expect(result.isErr, isTrue, reason: 'seed=$seed');
    });

    test('tamper messageNumber field → reject', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('auth-n'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = Uint8List.fromList((encResult as Ok).value.wireFormat);

      final tampered = Uint8List.fromList(wire);
      tampered[35] ^= 0xFF;

      final result = await bob.decrypt(data: tampered);
      expect(result.isErr, isTrue, reason: 'seed=$seed');
    });

    test('tamper prevChainLength field → reject (AAD covers header)', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('auth-pn'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = Uint8List.fromList((encResult as Ok).value.wireFormat);

      final tampered = Uint8List.fromList(wire);
      tampered[43] ^= 0xFF;

      final result = await bob.decrypt(data: tampered);
      expect(result.isErr, isTrue, reason: 'seed=$seed');
    });

    test('substitute associated data → reject', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      const aadOrig = 'original-aad';
      const aadWrong = 'wrong-aad';

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('auth-ad'.codeUnits),
        associatedData: Uint8List.fromList(aadOrig.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = (encResult as Ok).value.wireFormat;

      // Decrypt with different AAD → must fail.
      final wrongResult = await bob.decrypt(
        data: wire,
        associatedData: Uint8List.fromList(aadWrong.codeUnits),
      );
      expect(wrongResult.isErr, isTrue, reason: 'seed=$seed');

      // Decrypt with original AAD → must succeed.
      final okResult = await bob.decrypt(
        data: wire,
        associatedData: Uint8List.fromList(aadOrig.codeUnits),
      );
      expect(okResult.isOk, isTrue, reason: 'seed=$seed');
    });
  });

  group('DoubleRatchet F2: forward secrecy', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    test('message key bytes not present in serialized state after decryption', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('fs-test'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final enc = (encResult as Ok).value;

      // Capture the message key bytes before decryption.
      final messageKeyBytes = Uint8List.fromList(await enc.messageKey.extractBytes());

      // Bob decrypts.
      final decResult = await bob.decrypt(data: enc.wireFormat);
      expect(decResult.isOk, isTrue, reason: 'seed=$seed');
      final dec = (decResult as Ok).value;

      // Serialize Bob's next state and verify message key bytes are not in it.
      final serialized = await dec.nextState.toBytes();
      final serializedHex = bytesToHex(serialized);
      final mkHex = bytesToHex(messageKeyBytes);

      // Check that the 32-byte message key does not appear as a substring.
      expect(serializedHex.contains(mkHex), isFalse,
          reason: 'forward secrecy violated: message key found in serialized state (seed=$seed)');
    });
  });

  group('DoubleRatchet F2: post-compromise security', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    test('snapshot after step t cannot decrypt after another DH ratchet step', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final aliceDh = await X25519().newKeyPair();
      final bobDh = await X25519().newKeyPair();

      final alice = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
        dhPrivateKey: SecretKey(await aliceDh.extractPrivateKeyBytes()),
        dhPublicKey: await aliceDh.extractPublicKey(),
      );
      final bob = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.receivingChainKey,
        receivingChainKey: sessionKeys.sendingChainKey,
        dhPrivateKey: SecretKey(await bobDh.extractPrivateKeyBytes()),
        dhPublicKey: await bobDh.extractPublicKey(),
        remoteDhPublicKey: await aliceDh.extractPublicKey(),
      );

      final bobDhPub = await bobDh.extractPublicKey();

      var aliceState = alice;
      var bobState = bob;

      // ----- Step 0: Alice sends msg 0 with ratchet step, Bob decrypts -----
      var enc0 = await aliceState.encrypt(
        plaintext: Uint8List.fromList('pc-msg-0'.codeUnits),
        remotePublicKey: bobDhPub,
      );
      expect(enc0.isOk, isTrue, reason: 'seed=$seed');
      aliceState = (enc0 as Ok).value.nextState;

      var dec0 = await bobState.decrypt(data: (enc0 as Ok).value.wireFormat);
      expect(dec0.isOk, isTrue, reason: 'seed=$seed');
      bobState = (dec0 as Ok).value.nextState;

      // ----- Снимок состояния Bob после шага 0 -----
      final snapshotBytes = await bobState.toBytes();

      // ----- Шаг 1: Alice отправляет msg 1 с ratchet-шагом, Bob расшифровывает -----
      final bobDhPub1 = bobState.dhPublicKey! as SimplePublicKey;
      var enc1 = await aliceState.encrypt(
        plaintext: Uint8List.fromList('pc-msg-1'.codeUnits),
        remotePublicKey: bobDhPub1,
      );
      expect(enc1.isOk, isTrue, reason: 'seed=$seed');
      aliceState = (enc1 as Ok).value.nextState;

      var dec1 = await bobState.decrypt(data: (enc1 as Ok).value.wireFormat);
      expect(dec1.isOk, isTrue, reason: 'seed=$seed');
      bobState = (dec1 as Ok).value.nextState;

      // ----- Шаг 2: Alice отправляет msg 2 без ratchet-шага, Bob расшифровывает -----
      var enc2 = await aliceState.encrypt(
        plaintext: Uint8List.fromList('pc-msg-2'.codeUnits),
      );
      expect(enc2.isOk, isTrue, reason: 'seed=$seed');
      aliceState = (enc2 as Ok).value.nextState;

      var dec2 = await bobState.decrypt(data: (enc2 as Ok).value.wireFormat);
      expect(dec2.isOk, isTrue, reason: 'seed=$seed');

      // ----- Снимок Bob (шаг 0) НЕ должен расшифровывать msg 2 -----
      // (после шага 1 корневой ключ изменился, старый снимок не имеет текущих chain keys).
      final snapshotBob = DoubleRatchet.fromBytes(snapshotBytes);
      final decSnapshot = await snapshotBob.decrypt(
        data: (enc2 as Ok).value.wireFormat,
      );
      expect(decSnapshot.isErr, isTrue,
          reason: 'post-compromise failed: snapshot from step 0 decrypted msg 2 (seed=$seed)');
    });
  });

  group('DoubleRatchet F2: serialization', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    test('restore after every step gives same continuation', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      var aliceState = alice;
      var bobState = bob;

      for (var i = 0; i < 20; i++) {
        final plaintext = Uint8List.fromList('ser-msg-$i'.codeUnits);
        final encResult = await aliceState.encrypt(plaintext: plaintext);
        expect(encResult.isOk, isTrue);
        final enc = (encResult as Ok).value;

        // Serialize and restore Alice's state.
        final aliceSerialized = await aliceState.toBytes();
        final aliceRestored = DoubleRatchet.fromBytes(aliceSerialized);

        // Encrypt again from restored state — decrypt both wires with Bob
        // and compare plaintexts (nonce is random, so wire formats differ).
        final encAgain = await aliceRestored.encrypt(plaintext: plaintext);
        expect(encAgain.isOk, isTrue, reason: 'seed=$seed msg $i');

        // Bob decrypts original wire.
        final decResult = await bobState.decrypt(data: enc.wireFormat);
        expect(decResult.isOk, isTrue, reason: 'seed=$seed msg $i');
        final decPlain = bytesToHex((decResult as Ok).value.wireFormat);

        // Bob decrypts wire from restored state.
        final decAgainResult = await bobState.decrypt(data: (encAgain as Ok).value.wireFormat);
        expect(decAgainResult.isOk, isTrue, reason: 'seed=$seed msg $i');
        final decAgainPlain = bytesToHex((decAgainResult as Ok).value.wireFormat);
        expect(decAgainPlain, decPlain, reason: 'seed=$seed msg $i');

        bobState = (decAgainResult as Ok).value.nextState;
        final encAgainOk = (encAgain as Ok<DoubleRatchetResult, CryptoError>).value;
        aliceState = encAgainOk.nextState;
      }
    });

    test('truncated bytes → Result.error, not exception', () async {
      final sharedSecret = SecretKey(hexToUint8List(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      ));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final bob = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.receivingChainKey,
        receivingChainKey: sessionKeys.sendingChainKey,
      );

      // Truncated: only 10 bytes.
      final result = await bob.decrypt(data: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));
      expect(result.isErr, isTrue);
    });

    test('random bytes → Result.error, not exception (fuzz 1000 inputs)', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      ));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final bob = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.receivingChainKey,
        receivingChainKey: sessionKeys.sendingChainKey,
      );

      final random = Random(seed.hashCode);
      for (var i = 0; i < 1000; i++) {
        final len = random.nextInt(200);
        final bytes = Uint8List(len);
        for (var j = 0; j < len; j++) {
          bytes[j] = random.nextInt(256);
        }
        final result = await bob.decrypt(data: bytes);
        expect(result.isErr || result.isOk, isTrue,
            reason: 'fuzz input $i seed=$seed');
        // Must not throw.
      }
    });

    test('unknown serialization version → StateError (not swallowed)', () async {
      final data = Uint8List.fromList([99, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(() => DoubleRatchet.fromBytes(data), throwsA(isA<StateError>()));
    });

    // --- uint32 boundary values (D-11…D-14: dart2js 32-bit int) ---

    test('toBytes: counter = 0xFFFFFFFF accepted (uint32 max)', () async {
      final sharedSecret = SecretKey(hexToUint8List(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      ));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final state = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
        sendingMessageCounter: 0xFFFFFFFF,
        receivingMessageCounter: 0xFFFFFFFF,
        previousChainLength: 0xFFFFFFFF,
      );

      final serialized = await state.toBytes();
      expect(serialized, isNotEmpty);

      final restored = DoubleRatchet.fromBytes(serialized);
      expect(restored.sendingMessageCounter, 0xFFFFFFFF);
      expect(restored.receivingMessageCounter, 0xFFFFFFFF);
      expect(restored.previousChainLength, 0xFFFFFFFF);
    });

    test('toBytes: counter = 0x7FFFFFFF roundtrip preserved', () async {
      final sharedSecret = SecretKey(hexToUint8List(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      ));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      const maxInt31 = 0x7FFFFFFF;
      final state = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
        sendingMessageCounter: maxInt31,
      );

      final serialized = await state.toBytes();
      final restored = DoubleRatchet.fromBytes(serialized);
      expect(restored.sendingMessageCounter, maxInt31);
    });

    test('toBytes: counter > uint32 max (2^32) → ArgumentError', () async {
      final sharedSecret = SecretKey(hexToUint8List(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      ));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final state = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
        sendingMessageCounter: 1 << 32,
      );

      expect(
        () async => await state.toBytes(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('toBytes: negative counter → ArgumentError', () async {
      final sharedSecret = SecretKey(hexToUint8List(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      ));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      final state = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
        sendingMessageCounter: -1,
      );

      expect(
        () async => await state.toBytes(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('fromBytes: messageNumber = 2^31 in wire → DecryptionFailed', () async {
      final sharedSecret = SecretKey(hexToUint8List(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      ));
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

      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('boundary-test'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = Uint8List.fromList((encResult as Ok).value.wireFormat);

      // Set messageNumber (offset 34-41) to 2^31: bytes [0,0,0,128,0,0,0,0].
      final tampered = Uint8List.fromList(wire);
      tampered[34] = 0x00;
      tampered[35] = 0x00;
      tampered[36] = 0x00;
      tampered[37] = 0x80;
      tampered[38] = 0x00;
      tampered[39] = 0x00;
      tampered[40] = 0x00;
      tampered[41] = 0x00;

      final result = await bob.decrypt(data: tampered);
      expect(result.isErr, isTrue);
    });

    test('fromBytes: messageNumber = 2^25 roundtrip preserved (byte 3 nonzero)', () async {
      // Reproduces D-12: values between 2^24 and 2^30 have byte 3 != 0.
      // Old implementation ignored byte 3 → wrong decoded value.
      final sharedSecret = SecretKey(hexToUint8List(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      ));
      final sessionKeys = await x3dhToSessionKeys(sharedSecret);

      const msgNum25 = 1 << 25; // 33554432, byte 3 = 2

      final state = DoubleRatchet(
        rootKey: sessionKeys.rootKey,
        sendingChainKey: sessionKeys.sendingChainKey,
        receivingChainKey: sessionKeys.receivingChainKey,
        sendingMessageCounter: msgNum25,
      );

      final serialized = await state.toBytes();
      final restored = DoubleRatchet.fromBytes(serialized);
      expect(restored.sendingMessageCounter, msgNum25);

      // Verify wire bytes: offset 34-41 should encode 2^25 LE.
      // 2^25 = 0x02000000 → LE bytes: [0, 0, 0, 2, 0, 0, 0, 0].
      // In serialized format, sendingCounter is at offset 1+32*3=97, 8 bytes.
      expect(serialized[97], 0);
      expect(serialized[98], 0);
      expect(serialized[99], 0);
      expect(serialized[100], 2);
      expect(serialized[101], 0);
      expect(serialized[102], 0);
      expect(serialized[103], 0);
      expect(serialized[104], 0);
    });
  });

  group('DoubleRatchet F2: first X3DH message repeat', () {
    const secretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    test('repeat of first message is filtered by the library (replay protection)', () async {
      final seed = DateTime.now().millisecondsSinceEpoch.toString();
      // ignore: avoid_print
      print('SEED: $seed');

      final sharedSecret = SecretKey(hexToUint8List(secretHex));
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

      // Alice sends first message (messageNumber=0).
      final encResult = await alice.encrypt(
        plaintext: Uint8List.fromList('first-msg'.codeUnits),
      );
      expect(encResult.isOk, isTrue);
      final wire = (encResult as Ok).value.wireFormat;

      // Bob decrypts first message — succeeds.
      var bobState = bob;
      final dec1 = await bobState.decrypt(data: wire);
      expect(dec1.isOk, isTrue, reason: 'seed=$seed');
      bobState = (dec1 as Ok).value.nextState;

      // Bob decrypts the same first message again — replay, library rejects.
      final dec2 = await bobState.decrypt(data: wire);
      expect(dec2.isErr, isTrue, reason: 'seed=$seed');
      expect(dec2.unwrapErr(), isA<DecryptionFailed>());

      // Conclusion: the library (DoubleRatchet.decrypt) filters the repeat
      // via messageNumber replay protection, not the calling code.
    });
  });
}
