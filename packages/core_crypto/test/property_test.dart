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

/// Псевдослучайный генератор с фиксированным seed для воспроизводимости.
///
/// Seed печатается при падении теста, чтобы можно было воспроизвести
/// конкретный сценарий. Число итераций берётся из переменной окружения
/// OPEN_SINK_PROPERTY_ITERATIONS (по умолчанию 200 для CI).
class RandomWithSeed {
  final Random _random;
  final int seed;

  RandomWithSeed(this.seed) : _random = Random(seed);

  static int iterationCount() {
    try {
      const env = String.fromEnvironment('OPEN_SINK_PROPERTY_ITERATIONS');
      if (env.isNotEmpty) {
        return int.tryParse(env) ?? 200;
      }
    } catch (_) {}
    return 200;
  }

  int nextInt(int max) => _random.nextInt(max);

  bool nextBool() => _random.nextBool();

  void nextBytes(Uint8List bytes) {
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
  }
}

/// Генерирует случайный SecretKey длиной [length] байт.
Future<SecretKey> randomSecretKey(RandomWithSeed rnd, {int length = 32}) async {
  final bytes = Uint8List(length);
  rnd.nextBytes(bytes);
  return SecretKey(bytes);
}

/// Генерирует случайную Ed25519 ключевую пару.
Future<SimpleKeyPair> randomEd25519KeyPair(RandomWithSeed rnd) async {
  final seed = Uint8List(32);
  rnd.nextBytes(seed);
  final kp = await Ed25519().newKeyPairFromSeed(seed);
  return kp;
}

/// Генерирует случайную X25519 ключевую пару.
Future<SimpleKeyPair> randomX25519KeyPair(RandomWithSeed rnd) async {
  final seed = Uint8List(32);
  rnd.nextBytes(seed);
  final kp = await X25519().newKeyPairFromSeed(seed);
  return kp;
}

void main() {
  // ignore: avoid_print
  const envSeedRaw = String.fromEnvironment('OPEN_SINK_PROPERTY_SEED');
  final envSeed = envSeedRaw.isNotEmpty ? int.tryParse(envSeedRaw) ?? 0 : 0;
  final iterations = RandomWithSeed.iterationCount();

  // ignore: avoid_print
  print('PROPERTY_TEST_SEED=$envSeed');

  group('Property: AEAD (XChaCha20-Poly1305)', () {
    final boundaryLengths = [0, 1, 15, 16, 17, 63, 64, 65];

    test(
      'roundtrip + длина = len(pt) + 40 + битовые порчи + чужой ключ/AAD',
      () async {
        final rnd = RandomWithSeed(envSeed);
        final aead = XChaCha20Poly1305Aead();

        for (var i = 0; i < iterations; i++) {
          final key = await randomSecretKey(rnd);
          final wrongKey = await randomSecretKey(rnd);

          // Random plaintext length 0–64 KiB.
          final ptLen = rnd.nextInt(64 * 1024 + 1);
          final plaintext = Uint8List(ptLen);
          rnd.nextBytes(plaintext);

          // Sometimes use boundary lengths.
          if (i < boundaryLengths.length) {
            final bl = boundaryLengths[i];
            final bPlaintext = Uint8List(bl);
            rnd.nextBytes(bPlaintext);

            final encrypted = await aead.encrypt(
              key: key,
              plaintext: bPlaintext,
            );
            expect(encrypted.isOk, isTrue, reason: 'iter=$i len=$bl encrypt');
            final data = encrypted.unwrap();
            expect(
              data.length,
              equals(bl + 40),
              reason: 'iter=$i len=$bl wire length',
            );

            final decrypted = await aead.decrypt(key: key, data: data);
            expect(decrypted.isOk, isTrue, reason: 'iter=$i len=$bl decrypt');
            expect(
              decrypted.unwrap(),
              equals(bPlaintext),
              reason: 'iter=$i len=$bl roundtrip',
            );
          }

          // AAD (random, sometimes empty).
          final hasAad = rnd.nextBool();
          final aadBytes = Uint8List(rnd.nextInt(64));
          rnd.nextBytes(aadBytes);
          final Uint8List? aad = hasAad ? aadBytes : null;

          final encrypted = await aead.encrypt(
            key: key,
            plaintext: plaintext,
            aad: aad,
          );
          expect(encrypted.isOk, isTrue, reason: 'iter=$i encrypt');
          final data = encrypted.unwrap();
          expect(
            data.length,
            equals(ptLen + 40),
            reason: 'iter=$i wire length',
          );

          // Roundtrip with same key/AAD.
          final decrypted = await aead.decrypt(key: key, data: data, aad: aad);
          expect(decrypted.isOk, isTrue, reason: 'iter=$i decrypt');
          expect(
            decrypted.unwrap(),
            equals(plaintext),
            reason: 'iter=$i roundtrip',
          );

          // Wrong key → failure.
          final wrongDecrypt = await aead.decrypt(
            key: wrongKey,
            data: data,
            aad: aad,
          );
          expect(wrongDecrypt.isErr, isTrue, reason: 'iter=$i wrong key');

          // Wrong AAD → failure (if AAD was used).
          if (hasAad) {
            final tamperedAad = Uint8List.fromList(aadBytes)..[0] ^= 0xff;
            final wrongAadDecrypt = await aead.decrypt(
              key: key,
              data: data,
              aad: tamperedAad,
            );
            expect(wrongAadDecrypt.isErr, isTrue, reason: 'iter=$i wrong AAD');
          }

          // Flip one random bit in the wire data → failure.
          final tampered = Uint8List.fromList(data);
          final flipIdx = rnd.nextInt(tampered.length);
          tampered[flipIdx] ^= 0x01;
          final bitFlipDecrypt = await aead.decrypt(
            key: key,
            data: tampered,
            aad: aad,
          );
          expect(
            bitFlipDecrypt.isErr,
            isTrue,
            reason: 'iter=$i bit flip at $flipIdx',
          );
        }
      },
    );
  });

  group('Property: Signer (Ed25519)', () {
    test(
      'roundtrip + битовая порча данных/подписи → false + детерминизм',
      () async {
        final rnd = RandomWithSeed(envSeed);

        for (var i = 0; i < iterations; i++) {
          final keyPair = await randomEd25519KeyPair(rnd);
          final privateKeyBytes = Uint8List.fromList(
            await keyPair.extractPrivateKeyBytes(),
          );
          final publicKey = await keyPair.extractPublicKey();
          final publicKeyBytes = Uint8List.fromList((publicKey).bytes);

          final signer = CryptoSigner(SecretKey(privateKeyBytes));
          final peerId = PeerId(publicKeyBytes);

          final data = Uint8List(rnd.nextInt(256) + 1);
          rnd.nextBytes(data);

          // Roundtrip: sign → verify → true.
          final signature = await signer.sign(data);
          final valid = await signer.verify(data, signature, peerId);
          expect(valid, isTrue, reason: 'iter=$i roundtrip');

          // Determinism: same data → same signature.
          final signature2 = await signer.sign(data);
          expect(signature2, equals(signature), reason: 'iter=$i determinism');

          // Flip a bit in data → false.
          final tamperedData = Uint8List.fromList(data);
          tamperedData[0] ^= 0x01;
          final validTamperedData = await signer.verify(
            tamperedData,
            signature,
            peerId,
          );
          expect(validTamperedData, isFalse, reason: 'iter=$i tampered data');

          // Flip a bit in signature → false.
          final sigBytes = hexToBytes(signature);
          sigBytes[0] ^= 0x01;
          final validTamperedSig = await signer.verify(
            data,
            bytesToHex(sigBytes),
            peerId,
          );
          expect(
            validTamperedSig,
            isFalse,
            reason: 'iter=$i tampered signature',
          );

          // Wrong peerId → false.
          final wrongKeyPair = await randomEd25519KeyPair(rnd);
          final wrongPub = await wrongKeyPair.extractPublicKey();
          final wrongPeerId = PeerId(Uint8List.fromList((wrongPub).bytes));
          final validWrongPeer = await signer.verify(
            data,
            signature,
            wrongPeerId,
          );
          expect(validWrongPeer, isFalse, reason: 'iter=$i wrong peerId');
        }
      },
    );
  });

  group('Property: HKDF / GroupSecret', () {
    test('контексты попарно различны на случайных секретах', () async {
      final rnd = RandomWithSeed(envSeed);
      final hkdf = GroupHkdf();

      for (var i = 0; i < iterations; i++) {
        final secret = await randomSecretKey(rnd);

        final topic = await hkdf.deriveBytes(
          secret: secret,
          salt: Uint8List(32),
          info: GroupKeyContext.signalingTopic.info,
          length: 32,
        );
        final payloadKey = await hkdf.deriveBytes(
          secret: secret,
          salt: Uint8List(32),
          info: GroupKeyContext.signalingPayloadKey.info,
          length: 32,
        );
        final invitationKey = await hkdf.deriveBytes(
          secret: secret,
          salt: Uint8List(32),
          info: GroupKeyContext.invitationKey.info,
          length: 32,
        );

        // Контексты попарно различны.
        expect(
          bytesToHex(topic),
          isNot(bytesToHex(payloadKey)),
          reason: 'iter=$i topic != payload',
        );
        expect(
          bytesToHex(topic),
          isNot(bytesToHex(invitationKey)),
          reason: 'iter=$i topic != invitation',
        );
        expect(
          bytesToHex(payloadKey),
          isNot(bytesToHex(invitationKey)),
          reason: 'iter=$i payload != invitation',
        );

        // Детерминизм: тот же secret + тот же info → тот же вывод.
        final topic2 = await hkdf.deriveBytes(
          secret: secret,
          salt: Uint8List(32),
          info: GroupKeyContext.signalingTopic.info,
          length: 32,
        );
        expect(
          bytesToHex(topic2),
          equals(bytesToHex(topic)),
          reason: 'iter=$i topic determinism',
        );
      }
    });

    test('GroupSecret: topic/signaling/invitation попарно различны', () async {
      for (var i = 0; i < iterations; i++) {
        final groupSecret = await GroupSecret.random();

        final topic = await groupSecret.topic();
        final signalingKey = await groupSecret.signalingPayloadKey();
        final invitationKey = await groupSecret.invitationKey();

        final topicHex = await groupSecret.topicHex();

        // topicHex = hex(topic)
        expect(topicHex, equals(bytesToHex(topic)), reason: 'iter=$i topicHex');

        // Все три ключа попарно различны.
        final topicBytes = await groupSecret.topic();
        final sigKeyBytes = await signalingKey.extractBytes();
        final invKeyBytes = await invitationKey.extractBytes();

        expect(
          bytesToHex(topicBytes),
          isNot(bytesToHex(sigKeyBytes)),
          reason: 'iter=$i topic != signaling',
        );
        expect(
          bytesToHex(topicBytes),
          isNot(bytesToHex(invKeyBytes)),
          reason: 'iter=$i topic != invitation',
        );
        expect(
          bytesToHex(sigKeyBytes),
          isNot(bytesToHex(invKeyBytes)),
          reason: 'iter=$i signaling != invitation',
        );

        // toString не раскрывает секреты.
        expect(
          groupSecret.toString(),
          contains('<secret>'),
          reason: 'iter=$i GroupSecret toString',
        );
      }
    });
  });

  group('Property: X3DH', () {
    test(
      'случайные участники: roundtrip + разные бандлы → разные ключи',
      () async {
        final x3dh = X3DH();

        for (var i = 0; i < iterations; i++) {
          final bobBundle = await x3dh.generateKeyBundle();

          // Alice sends to Bob.
          final senderResult = await x3dh.sender(
            remoteBundle: bobBundle.toPublicBundle(),
          );
          expect(senderResult.isOk, isTrue, reason: 'iter=$i sender ok');
          final senderShared =
              (senderResult as Ok<X3DHSenderResult, CryptoError>)
                  .value
                  .sharedKey;
          final senderBytes = await senderShared.extractBytes();
          expect(
            senderBytes,
            hasLength(32),
            reason: 'iter=$i shared key length',
          );

          // Bob receives from Alice.
          final receiverShared = await x3dh.receiver(
            bundle: bobBundle,
            senderEphemeralPublicKey: senderResult.unwrap().ephemeralPublicKey,
          );
          final receiverBytes = await receiverShared.extractBytes();
          expect(
            bytesToHex(senderBytes),
            equals(bytesToHex(receiverBytes)),
            reason: 'iter=$i roundtrip match',
          );

          // Different bundles → different shared keys.
          if (i % 10 == 0) {
            final charlieBundle = await x3dh.generateKeyBundle();
            final charlieResult = await x3dh.sender(
              remoteBundle: charlieBundle.toPublicBundle(),
            );
            expect(
              charlieResult.isOk,
              isTrue,
              reason: 'iter=$i charlie sender ok',
            );
            final charlieShared = (charlieResult as Ok).value.sharedKey;
            final charlieBytes = await charlieShared.extractBytes();
            expect(
              bytesToHex(senderBytes),
              isNot(bytesToHex(charlieBytes)),
              reason: 'iter=$i different bundles',
            );
          }
        }
      },
    );

    test(
      'негативы: неверная подпись SPK → отказ; отсутствие подписи → отказ',
      () async {
        final x3dh = X3DH();

        for (var i = 0; i < iterations ~/ 10; i++) {
          final bundle = await x3dh.generateKeyBundle();
          final publicBundle = bundle.toPublicBundle();

          // Tampered SPK signature.
          final tampered = X3DHPublicBundle(
            identityKey: publicBundle.identityKey,
            signedPrekey: publicBundle.signedPrekey,
            ed25519PublicKey: publicBundle.ed25519PublicKey,
            signedPrekeySignature: '00' * 64,
          );
          final result = await x3dh.sender(remoteBundle: tampered);
          expect(result.isErr, isTrue, reason: 'iter=$i tampered sig');
          expect(
            result.unwrapErr(),
            isA<InvalidSignature>(),
            reason: 'iter=$i invalid signature',
          );

          // Missing signature.
          final noSig = X3DHPublicBundle(
            identityKey: publicBundle.identityKey,
            signedPrekey: publicBundle.signedPrekey,
            ed25519PublicKey: publicBundle.ed25519PublicKey,
            signedPrekeySignature: null,
          );
          final noSigResult = await x3dh.sender(remoteBundle: noSig);
          expect(noSigResult.isErr, isTrue, reason: 'iter=$i no sig');
        }
      },
    );
  });

  group('Property: Sender Keys', () {
    test('случайные участники и порядки: encrypt/decrypt + replay + разные senderPeerId', () async {
      final rnd = RandomWithSeed(envSeed);

      for (var i = 0; i < iterations; i++) {
        final chainKey = await generateAeadKey();
        final signingKeyPair = await Ed25519().newKeyPair();
        final signingPub = await signingKeyPair.extractPublicKey();

        final groupId = 'group-${rnd.nextInt(1000)}';
        final senderPeerId = 'peer-${rnd.nextInt(100)}';

        final key = SenderKey(
          chainKey: chainKey,
          signingKeyPair: signingKeyPair,
          sequenceNumber: 0,
          groupId: groupId,
          senderPeerId: senderPeerId,
        );

        final data = Uint8List(rnd.nextInt(256) + 1);
        rnd.nextBytes(data);

        // Encrypt.
        final encrypted = await key.encrypt(plaintext: data);
        expect(encrypted.isOk, isTrue, reason: 'iter=$i encrypt ok');
        final result = encrypted.unwrap();

        // Decrypt with same chain key.
        final decrypted = await SenderKey.decrypt(
          chainKey: chainKey,
          signingPublicKey: signingPub,
          expectedIteration: 0,
          ciphertext: result.ciphertext,
          signature: result.signature,
          groupId: groupId,
          senderPeerId: senderPeerId,
        );
        expect(decrypted.isOk, isTrue, reason: 'iter=$i decrypt ok');
        expect(decrypted.unwrap(), equals(data), reason: 'iter=$i roundtrip');

        // Wrong iteration → should fail (signature covers iteration).
        final wrongIter = await SenderKey.decrypt(
          chainKey: chainKey,
          signingPublicKey: signingPub,
          expectedIteration: 1,
          ciphertext: result.ciphertext,
          signature: result.signature,
          groupId: groupId,
          senderPeerId: senderPeerId,
        );
        expect(wrongIter.isErr, isTrue, reason: 'iter=$i wrong iteration');

        // Tampered ciphertext → failure.
        final tampered = Uint8List.fromList(result.ciphertext);
        tampered[0] ^= 0x01;
        final tamperedDecrypt = await SenderKey.decrypt(
          chainKey: chainKey,
          signingPublicKey: signingPub,
          expectedIteration: 0,
          ciphertext: tampered,
          signature: result.signature,
          groupId: groupId,
          senderPeerId: senderPeerId,
        );
        expect(
          tamperedDecrypt.isErr,
          isTrue,
          reason: 'iter=$i tampered ciphertext',
        );

        // Different senderPeerId → failure (AAD mismatch).
        final wrongPeer = await SenderKey.decrypt(
          chainKey: chainKey,
          signingPublicKey: signingPub,
          expectedIteration: 0,
          ciphertext: result.ciphertext,
          signature: result.signature,
          groupId: groupId,
          senderPeerId: 'other-peer',
        );
        expect(wrongPeer.isErr, isTrue, reason: 'iter=$i wrong peerId');
      }
    });
  });

  group('Property: fuzz десериализаторов и парсеров', () {
    test('случайные байты никогда не бросают неожидаемые исключения (DoubleRatchet.fromBytes)', () async {
      final rnd = RandomWithSeed(envSeed);

      for (var i = 0; i < iterations; i++) {
        final len = rnd.nextInt(200);
        final bytes = Uint8List(len);
        rnd.nextBytes(bytes);

        try {
          DoubleRatchet.fromBytes(bytes);
        } on StateError {
          // Expected for bad version or truncated data.
        } on RangeError {
          // Expected for truncated input.
        } catch (e) {
          fail('iter=$i unexpected exception type: ${e.runtimeType} — $e');
        }
      }
    });

    test('Bip39.mnemonicToEntropy: случайные слова не бросают неожидаемые исключения', () async {
      final rnd = RandomWithSeed(envSeed);

      for (var i = 0; i < iterations ~/ 10; i++) {
        final wordCount = 3 + rnd.nextInt(22); // 3..24
        final words = <String>[];
        for (var j = 0; j < wordCount; j++) {
          words.add(
            bip39EnglishWordlist[rnd.nextInt(bip39EnglishWordlist.length)],
          );
        }

        try {
          Bip39.mnemonicToEntropy(words);
        } on ArgumentError {
          // Expected: unknown word or bad checksum.
        } catch (e) {
          fail('iter=$i unexpected exception: ${e.runtimeType} — $e');
        }
      }
    });
  });
}
