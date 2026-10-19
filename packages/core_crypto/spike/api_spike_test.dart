import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

/// API-spike package:cryptography v2.9.0 (зафиксировано в pubspec.lock).
/// Одноразовые проверки привязки API — не входят в основной прогон `dart test test/`.
void main() {
  group('spike: Ed25519 newKeyPairFromSeed', () {
    test('открытый ключ соответствует приватному из того же seed', () async {
      final algo = Ed25519();
      final seed = List<int>.filled(32, 0x42);
      final kp1 = await algo.newKeyPairFromSeed(seed);
      final pub1 = await kp1.extractPublicKey();
      final priv1 = await kp1.extractPrivateKeyBytes();

      // повторный вызов с тем же seed — детерминизм
      final kp2 = await algo.newKeyPairFromSeed(seed);
      final pub2 = await kp2.extractPublicKey();
      final priv2 = await kp2.extractPrivateKeyBytes();

      expect(pub1.bytes, equals(pub2.bytes));
      expect(priv1, equals(priv2));
      expect(pub1.bytes, hasLength(32));
      expect(priv1, hasLength(32));
    });

    test('подпись и верификация по ключу из newKeyPairFromSeed', () async {
      final algo = Ed25519();
      final seed = List<int>.filled(32, 0x21);
      final kp = await algo.newKeyPairFromSeed(seed);
      final pub = await kp.extractPublicKey();

      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final sig = await algo.sign(data, keyPair: kp);
      expect(sig.bytes, hasLength(64));

      final ok = await algo.verify(data, signature: sig);
      expect(ok, isTrue);

      // чужие данные — не проходит
      final bad = await algo.verify(
        Uint8List.fromList([9, 9, 9]),
        signature: sig,
      );
      expect(bad, isFalse);
    });
  });

  group('spike: X25519 newKeyPairFromSeed + sharedSecretKey', () {
    test('два участника получают одинаковый общий секрет', () async {
      final x = X25519();
      final alice = await x.newKeyPairFromSeed(List<int>.filled(32, 0x03));
      final bob = await x.newKeyPairFromSeed(List<int>.filled(32, 0x07));

      final apub = await alice.extractPublicKey();
      final bpub = await bob.extractPublicKey();

      final s1 = await x.sharedSecretKey(
        keyPair: alice,
        remotePublicKey: bpub,
      );
      final s2 = await x.sharedSecretKey(
        keyPair: bob,
        remotePublicKey: apub,
      );

      final b1 = await s1.extractBytes();
      final b2 = await s2.extractBytes();

      expect(b1, hasLength(32));
      expect(b2, hasLength(32));
      expect(b1, equals(b2));
    });
  });

  group('spike: XChaCha20-Poly1305', () {
    test('имя/конструктор, длины nonce и MAC', () async {
      // Точное имя в v2.9.0: Xchacha20.poly1305Aead() (строчная 'chacha').
      final algo = Xchacha20.poly1305Aead();
      expect(algo.nonceLength, equals(24));
      expect(algo.secretKeyLength, equals(32));

      final key = await algo.newSecretKey();
      final plaintext = Uint8List.fromList(utf8.encode('spike-plaintext'));

      final box = await algo.encrypt(plaintext, secretKey: key);
      expect(box.nonce, hasLength(24));
      expect(box.mac.bytes, hasLength(16));
      expect(box.cipherText, isNotEmpty);

      final pt = await algo.decrypt(box, secretKey: key);
      expect(pt, equals(plaintext));
    });

    test('неверный MAC -> SecretBoxAuthenticationError, не иное исключение', () async {
      final algo = Xchacha20.poly1305Aead();
      final key = await algo.newSecretKey();
      final box = await algo.encrypt(
        Uint8List.fromList(utf8.encode('x')),
        secretKey: key,
      );

      final tampered = SecretBox(
        box.cipherText,
        nonce: box.nonce,
        mac: Mac(Uint8List.fromList(List<int>.filled(16, 0xff))),
      );

      expect(
        () => algo.decrypt(tampered, secretKey: key),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('spike: Hkdf / Pbkdf2 параметры', () {
    test('Hkdf: hmac, outputLength, nonce, info', () async {
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final derived = await hkdf.deriveKey(
        secretKey: SecretKey(List<int>.filled(32, 0x0b)),
        nonce: List<int>.filled(13, 0x00),
        info: List<int>.filled(10, 0xf0),
      );
      final bytes = await derived.extractBytes();
      expect(bytes, hasLength(32));
    });

    test('Pbkdf2: macAlgorithm, iterations, bits', () async {
      final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha512(),
        iterations: 2048,
        bits: 512,
      );
      final derived = await pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode('password')),
        nonce: utf8.encode('salt'),
      );
      final bytes = await derived.extractBytes();
      expect(bytes, hasLength(64)); // 512 bits
    });
  });
}
