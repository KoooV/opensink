import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

void main() {
  group('XChaCha20Poly1305Aead', () {
    const keyHex =
        '808182838485868788898a8b8c8d8e8f'
        '909192939495969798999a9b9c9d9e9f';

    test('encrypt/decrypt roundtrip', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey.fromBytes(
        Uint8List.fromList(
          List<int>.generate(32, (i) => i),
        ),
      );
      const plaintext = 'Hello, OpenSink!';
      final data = Uint8List.fromList(utf8.encode(plaintext));
      final aad = Uint8List.fromList(utf8.encode('associated-data'));

      final encrypted = await aead.encrypt(
        key: key,
        plaintext: data,
        aad: aad,
      );
      expect(encrypted.isOk, isTrue);
      final ciphertext = encrypted.unwrap();
      expect(ciphertext.length, greaterThan(data.length));
      expect(ciphertext.length, equals(data.length + 24 + 16)); // nonce + mac

      final decrypted = await aead.decrypt(
        key: key,
        data: ciphertext,
        aad: aad,
      );
      expect(decrypted.isOk, isTrue);
      expect(decrypted.unwrap(), equals(data));
    });

    test('tampered ciphertext fails', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey.fromBytes(
        Uint8List.fromList(
          List<int>.generate(32, (i) => i),
        ),
      );
      const plaintext = 'Hello, OpenSink!';
      final data = Uint8List.fromList(utf8.encode(plaintext));

      final encrypted = await aead.encrypt(
        key: key,
        plaintext: data,
      );
      expect(encrypted.isOk, isTrue);
      final ciphertext = Uint8List.fromList(encrypted.unwrap());

      // Flip a byte in the ciphertext (not nonce).
      final tampered = Uint8List.fromList(ciphertext);
      tampered[tampered.length - 1] ^= 0xff;

      final decrypted = await aead.decrypt(
        key: key,
        data: tampered,
      );
      expect(decrypted.isErr, isTrue);
      expect(decrypted.unwrapErr(), isA<DecryptionFailed>());
    });

    test('wrong key fails', () async {
      final aead = XChaCha20Poly1305Aead();
      const keyHex =
          '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final key = SecretKey.fromBytes(
        Uint8List.fromList(
          keyHex.bytes.map((c) => int.parse(c.toRadixString(16), radix: 16)),
        ),
      );
      // Actually use a simpler key
      final keyBytes = Uint8List(32);
      final wrongKey = SecretKey.fromBytes(Uint8List.fromList(
        List<int>.generate(32, (i) => 255 - i),
      ));

      const plaintext = 'Test';
      final data = Uint8List.fromList(utf8.encode(plaintext));

      final encrypted = await aead.encrypt(key: key, plaintext: data);
      expect(encrypted.isOk, isTrue);

      final decrypted = await aead.decrypt(
        key: wrongKey,
        data: encrypted.unwrap(),
      );
      expect(decrypted.isErr, isTrue);
    });

    test('data too short fails', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey.fromBytes(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );

      final decrypted = await aead.decrypt(
        key: key,
        data: Uint8List.fromList([1, 2, 3]),
      );
      expect(decrypted.isErr, isTrue);
      expect(decrypted.unwrapErr(), isA<DecryptionFailed>());
    });

    test('property: different plaintexts produce different ciphertexts', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey.fromBytes(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );

      final p1 = Uint8List.fromList(utf8.encode('message one'));
      final p2 = Uint8List.fromList(utf8.encode('message two'));

      final c1 = await aead.encrypt(key: key, plaintext: p1);
      final c2 = await aead.encrypt(key: key, plaintext: p2);

      expect(c1.isOk, isTrue);
      expect(c2.isOk, isTrue);
      expect(c1.unwrap(), isNot(equals(c2.unwrap())));
    });
  });
}
