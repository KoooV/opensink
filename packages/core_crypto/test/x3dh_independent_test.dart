import 'dart:convert';
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

/// Независимый (вне класса X3DH) пересчёт общего секрета по формуле X3DH:
///
///   dh2 = X25519(ephemeral_priv, IK_recipient_pub)
///   dh3 = X25519(ephemeral_priv, SPK_recipient_pub)
///   SK  = HKDF-SHA-256(dh2 || dh3, salt=0^32, info="opensink/x3dh/shared-key", 32)
///
/// Не вызывает методы класса X3DH — только X25519.sharedSecretKey и HKDF.
/// Это ловит ошибки композиции (перестановка DH, неверный info, неверный порядок конкатенации).
Future<SecretKey> computeSharedKeyIndependent({
  required SecretKey ephemeralPrivateKey,
  required PublicKey ephemeralPublicKey,
  required PublicKey recipientIk,
  required PublicKey recipientSpk,
}) async {
  final x25519 = X25519();

  final ephemeralPrivBytes = await ephemeralPrivateKey.extractBytes();
  final ephemeralPair = SimpleKeyPairData(
    ephemeralPrivBytes,
    publicKey: ephemeralPublicKey as SimplePublicKey,
    type: KeyPairType.x25519,
  );

  final dh2 = await x25519.sharedSecretKey(
    keyPair: ephemeralPair,
    remotePublicKey: recipientIk,
  );
  final dh3 = await x25519.sharedSecretKey(
    keyPair: ephemeralPair,
    remotePublicKey: recipientSpk,
  );

  final dh2Bytes = Uint8List.fromList(await dh2.extractBytes());
  final dh3Bytes = Uint8List.fromList(await dh3.extractBytes());
  final combined = Uint8List.fromList([...dh2Bytes, ...dh3Bytes]);

  final hkdf = GroupHkdf();
  return await hkdf.derive(
    secret: SecretKey(combined),
    salt: Uint8List(32),
    info: Uint8List.fromList(utf8.encode('opensink/x3dh/shared-key')),
    outputLength: 32,
  );
}

void main() {
  group('X3DH: независимый пересчёт (без вызова кода X3DH)', () {
    test(
      'SK совпадает с результатом X3DH.receiver (DH коммутативность)',
      () async {
        final x3dh = X3DH();

        final aliceBundle = await x3dh.generateKeyBundle();

        // Bob (отправитель) вычисляет через X3DH, используя публичный бандл Алисы.
        final senderResult = await x3dh.sender(
          remoteBundle: aliceBundle.toPublicBundle(),
        );
        expect(senderResult.isOk, isTrue);
        final senderShared =
            (senderResult as Ok<X3DHSenderResult, CryptoError>).value;

        // Независимый пересчёт с позиции Алисы: её приватные IK/SPK + эфемерный pub Bob.
        // DH(Alice_IK_priv, Bob_Ephemeral_pub) == DH(Bob_Ephemeral_priv, Alice_IK_pub) — коммутативность.
        final aliceIkPrivBytes = await aliceBundle.identityPrivateKey
            .extractBytes();
        final aliceSpkPrivBytes = await aliceBundle.signedPrekeyPrivateKey
            .extractBytes();

        final aliceIkPair = SimpleKeyPairData(
          aliceIkPrivBytes,
          publicKey: aliceBundle.identityKey as SimplePublicKey,
          type: KeyPairType.x25519,
        );
        final aliceSpkPair = SimpleKeyPairData(
          aliceSpkPrivBytes,
          publicKey: aliceBundle.signedPrekey as SimplePublicKey,
          type: KeyPairType.x25519,
        );

        final x25519 = X25519();
        final dh2 = await x25519.sharedSecretKey(
          keyPair: aliceIkPair,
          remotePublicKey: senderShared.ephemeralPublicKey,
        );
        final dh3 = await x25519.sharedSecretKey(
          keyPair: aliceSpkPair,
          remotePublicKey: senderShared.ephemeralPublicKey,
        );

        final dh2Bytes = Uint8List.fromList(await dh2.extractBytes());
        final dh3Bytes = Uint8List.fromList(await dh3.extractBytes());
        final combined = Uint8List.fromList([...dh2Bytes, ...dh3Bytes]);

        final hkdf = GroupHkdf();
        final independentSk = await hkdf.derive(
          secret: SecretKey(combined),
          salt: Uint8List(32),
          info: Uint8List.fromList(utf8.encode('opensink/x3dh/shared-key')),
          outputLength: 32,
        );

        final independentBytes = await independentSk.extractBytes();
        final receiverBytes = await x3dh
            .receiver(
              bundle: aliceBundle,
              senderEphemeralPublicKey: senderShared.ephemeralPublicKey,
            )
            .then((k) => k.extractBytes());
        final senderBytes = await senderShared.sharedKey.extractBytes();

        expect(
          bytesToHex(senderBytes),
          equals(bytesToHex(receiverBytes)),
          reason: 'X3DH sender SK == X3DH receiver SK',
        );
        expect(
          bytesToHex(independentBytes),
          equals(bytesToHex(receiverBytes)),
          reason: 'Independent SK (Alice perspective) == X3DH receiver SK',
        );
        expect(
          bytesToHex(independentBytes),
          equals(bytesToHex(senderBytes)),
          reason: 'Independent SK == X3DH sender SK',
        );
      },
    );

    test(
      'перестановка порядка DH (dh3 || dh2 вместо dh2 || dh3) → другой SK',
      () async {
        final x3dh = X3DH();
        final aliceBundle = await x3dh.generateKeyBundle();

        final senderResult = await x3dh.sender(
          remoteBundle: aliceBundle.toPublicBundle(),
        );
        expect(senderResult.isOk, isTrue);
        final normalBytes = await senderResult
            .unwrap()
            .sharedKey
            .extractBytes();

        // Независимый пересчёт с переставленным порядком: dh3 || dh2.
        final aliceIkPrivBytes = await aliceBundle.identityPrivateKey
            .extractBytes();
        final aliceSpkPrivBytes = await aliceBundle.signedPrekeyPrivateKey
            .extractBytes();

        final aliceIkPair = SimpleKeyPairData(
          aliceIkPrivBytes,
          publicKey: aliceBundle.identityKey as SimplePublicKey,
          type: KeyPairType.x25519,
        );
        final aliceSpkPair = SimpleKeyPairData(
          aliceSpkPrivBytes,
          publicKey: aliceBundle.signedPrekey as SimplePublicKey,
          type: KeyPairType.x25519,
        );

        final x25519 = X25519();
        final dh2 = await x25519.sharedSecretKey(
          keyPair: aliceIkPair,
          remotePublicKey: senderResult.unwrap().ephemeralPublicKey,
        );
        final dh3 = await x25519.sharedSecretKey(
          keyPair: aliceSpkPair,
          remotePublicKey: senderResult.unwrap().ephemeralPublicKey,
        );

        final dh2Bytes = Uint8List.fromList(await dh2.extractBytes());
        final dh3Bytes = Uint8List.fromList(await dh3.extractBytes());

        // Переставляем: dh3 || dh2 вместо dh2 || dh3.
        final swapped = Uint8List.fromList([...dh3Bytes, ...dh2Bytes]);

        final hkdf = GroupHkdf();
        final swappedSk = await hkdf.derive(
          secret: SecretKey(swapped),
          salt: Uint8List(32),
          info: Uint8List.fromList(utf8.encode('opensink/x3dh/shared-key')),
          outputLength: 32,
        );
        final swappedBytes = await swappedSk.extractBytes();

        expect(
          bytesToHex(normalBytes),
          isNot(bytesToHex(swappedBytes)),
          reason: 'перестановка dh2/dh3 должна давать другой SK',
        );
      },
    );

    test('замена info → другой SK', () async {
      final x3dh = X3DH();
      final aliceBundle = await x3dh.generateKeyBundle();

      final senderResult = await x3dh.sender(
        remoteBundle: aliceBundle.toPublicBundle(),
      );
      expect(senderResult.isOk, isTrue);
      final normalBytes = await senderResult.unwrap().sharedKey.extractBytes();

      final aliceIkPrivBytes = await aliceBundle.identityPrivateKey
          .extractBytes();
      final aliceSpkPrivBytes = await aliceBundle.signedPrekeyPrivateKey
          .extractBytes();

      final aliceIkPair = SimpleKeyPairData(
        aliceIkPrivBytes,
        publicKey: aliceBundle.identityKey as SimplePublicKey,
        type: KeyPairType.x25519,
      );
      final aliceSpkPair = SimpleKeyPairData(
        aliceSpkPrivBytes,
        publicKey: aliceBundle.signedPrekey as SimplePublicKey,
        type: KeyPairType.x25519,
      );

      final x25519 = X25519();
      final dh2 = await x25519.sharedSecretKey(
        keyPair: aliceIkPair,
        remotePublicKey: senderResult.unwrap().ephemeralPublicKey,
      );
      final dh3 = await x25519.sharedSecretKey(
        keyPair: aliceSpkPair,
        remotePublicKey: senderResult.unwrap().ephemeralPublicKey,
      );

      final dh2Bytes = Uint8List.fromList(await dh2.extractBytes());
      final dh3Bytes = Uint8List.fromList(await dh3.extractBytes());
      final combined = Uint8List.fromList([...dh2Bytes, ...dh3Bytes]);

      final hkdf = GroupHkdf();
      const wrongInfo = 'opensink/x3dh/wrong-info';
      final wrongSk = await hkdf.derive(
        secret: SecretKey(combined),
        salt: Uint8List(32),
        info: Uint8List.fromList(utf8.encode(wrongInfo)),
        outputLength: 32,
      );
      final wrongBytes = await wrongSk.extractBytes();

      expect(
        bytesToHex(normalBytes),
        isNot(bytesToHex(wrongBytes)),
        reason: 'замена info должна давать другой SK',
      );
    });

    test('подмена SPK → отказ (неверная привязка подписи)', () async {
      final x3dh = X3DH();
      final aliceBundle = await x3dh.generateKeyBundle();
      final charlieBundle = await x3dh.generateKeyBundle();

      // Подменяем SPK Алисы на чужой, но оставляем старую подпись.
      // Подпись была вычислена над старым SPK → не соответствует новому → отказ.
      final tamperedSpk = X3DHPublicBundle(
        identityKey: aliceBundle.identityKey,
        signedPrekey: charlieBundle.signedPrekey, // чужой SPK
        ed25519PublicKey: aliceBundle.ed25519PublicKey,
        signedPrekeySignature: aliceBundle.signedPrekeySignature,
      );

      final result = await x3dh.sender(remoteBundle: tamperedSpk);
      expect(result.isErr, isTrue, reason: 'подмена SPK → отказ');
      expect(
        result.unwrapErr(),
        isA<InvalidSignature>(),
        reason: 'подмена SPK → InvalidSignature',
      );
    });

    test(
      'подмена ed25519PublicKey → отказ (подпись не верифицируется)',
      () async {
        final x3dh = X3DH();
        final aliceBundle = await x3dh.generateKeyBundle();
        final charlieBundle = await x3dh.generateKeyBundle();

        // Подменяем ключ подписи на чужой. Старая подпись была сделана ключом Алисы,
        // поэтому с чужым открытым ключом подпись не верифицируется.
        final tamperedEdKey = X3DHPublicBundle(
          identityKey: aliceBundle.identityKey,
          signedPrekey: aliceBundle.signedPrekey,
          ed25519PublicKey:
              charlieBundle.ed25519PublicKey, // чужой ключ подписи
          signedPrekeySignature: aliceBundle.signedPrekeySignature,
        );

        final result = await x3dh.sender(remoteBundle: tamperedEdKey);
        expect(
          result.isErr,
          isTrue,
          reason: 'подмена ed25519PublicKey → отказ',
        );
      },
    );

    test('regression-вектор: фиксированные seed → стабильный roundtrip (самосгенерированный)', () async {
      // Вектор из test/vectors/x3dh_regression.json — самосгенерированный,
      // не независимая проверка. sharedKey не фиксирован (эфемерный ключ случайный),
      // поэтому проверяем только стабильность roundtrip и длину ключа.
      const regressionAliceIk =
          '0000000000000000000000000000000000000000000000000000000000000000';
      const regressionAliceSpk =
          '1111111111111111111111111111111111111111111111111111111111111111';
      const regressionAliceEd =
          '2222222222222222222222222222222222222222222222222222222222222222';

      final x3dh = X3DH();
      final x25519 = X25519();
      final ed25519 = Ed25519();
      const signingContext = 'opensink/x3dh/spk-binding/v1|';

      // Alice's bundle из фиксированных seed.
      final aliceIkPair = await x25519.newKeyPairFromSeed(
        hexToUint8List(regressionAliceIk),
      );
      final aliceSpkPair = await x25519.newKeyPairFromSeed(
        hexToUint8List(regressionAliceSpk),
      );
      final aliceEdPair = await ed25519.newKeyPairFromSeed(
        hexToUint8List(regressionAliceEd),
      );

      final aliceIkPub = await aliceIkPair.extractPublicKey();
      final aliceSpkPub = await aliceSpkPair.extractPublicKey();
      final aliceEdPub = await aliceEdPair.extractPublicKey();
      final aliceIkPriv = await aliceIkPair.extractPrivateKeyBytes();
      final aliceSpkPriv = await aliceSpkPair.extractPrivateKeyBytes();

      final aliceSigningInput = Uint8List.fromList([
        ...utf8.encode(signingContext),
        ...aliceSpkPub.bytes,
      ]);
      final aliceSpkSig = await ed25519.sign(
        aliceSigningInput,
        keyPair: aliceEdPair,
      );

      final aliceBundle = X3DHKeyBundle(
        identityKey: aliceIkPub,
        identityPrivateKey: SecretKey(aliceIkPriv),
        signedPrekey: aliceSpkPub,
        signedPrekeyPrivateKey: SecretKey(aliceSpkPriv),
        ed25519PublicKey: aliceEdPub,
        signedPrekeySignature: bytesToHex(aliceSpkSig.bytes),
      );

      // Roundtrip: Bob отправляет Alice (использует публичный бандл Алисы).
      final senderResult = await x3dh.sender(
        remoteBundle: aliceBundle.toPublicBundle(),
      );
      expect(senderResult.isOk, isTrue);
      final senderBytes = await senderResult.unwrap().sharedKey.extractBytes();
      expect(senderBytes, hasLength(32));

      // Alice принимает от Bob.
      final receiverShared = await x3dh.receiver(
        bundle: aliceBundle,
        senderEphemeralPublicKey: senderResult.unwrap().ephemeralPublicKey,
      );
      final receiverBytes = await receiverShared.extractBytes();

      expect(
        bytesToHex(senderBytes),
        equals(bytesToHex(receiverBytes)),
        reason: 'regression-вектор: sender == receiver roundtrip',
      );
    });
  });
}
