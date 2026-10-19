import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

void main() {
  group('XChaCha20Poly1305Aead', () {
    test('encrypt/decrypt roundtrip', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
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
      expect(ciphertext.length, equals(data.length + 12 + 16)); // nonce + tag

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
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      const plaintext = 'Hello, OpenSink!';
      final data = Uint8List.fromList(utf8.encode(plaintext));

      final encrypted = await aead.encrypt(key: key, plaintext: data);
      expect(encrypted.isOk, isTrue);
      final ciphertext = Uint8List.fromList(encrypted.unwrap());

      final tampered = Uint8List.fromList(ciphertext);
      tampered[tampered.length - 1] ^= 0xff;

      final decrypted = await aead.decrypt(key: key, data: tampered);
      expect(decrypted.isErr, isTrue);
      expect(decrypted.unwrapErr(), isA<DecryptionFailed>());
    });

    test('wrong key fails', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      final wrongKey = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => 255 - i)),
      );

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
      final key = SecretKey(
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
      final key = SecretKey(
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

    test('property: same plaintext twice produces different ciphertexts (random nonce)', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );

      const plaintext = 'Same message';
      final data = Uint8List.fromList(utf8.encode(plaintext));

      final c1 = await aead.encrypt(key: key, plaintext: data);
      final c2 = await aead.encrypt(key: key, plaintext: data);

      expect(c1.isOk, isTrue);
      expect(c2.isOk, isTrue);
      // Nonce is random (24 bytes), so ciphertexts should differ with overwhelming probability
      expect(c1.unwrap(), isNot(equals(c2.unwrap())));
      // But both decrypt correctly
      final d1 = await aead.decrypt(key: key, data: c1.unwrap());
      final d2 = await aead.decrypt(key: key, data: c2.unwrap());
      expect(d1.unwrap(), equals(data));
      expect(d2.unwrap(), equals(data));
    });
  });

  group('CryptoSigner raw bytes', () {
    test('signs exactly the bytes passed (not canonical JSON)', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);

      final wireBytes = Uint8List.fromList([0x0a, 0x07, 0x74, 0x65, 0x73, 0x74]);

      final signature = await signer.sign(wireBytes);
      final valid = await signer.verify(wireBytes, signature, identity.peerId);
      expect(valid, isTrue);
    });

    test('signature over raw bytes does not verify over JSON bytes', () async {
      final identity = await generateIdentity();
      final signer = CryptoSigner(identity.ed25519PrivateKey);

      final rawBytes = Uint8List.fromList([1, 2, 3]);
      final jsonBytes = Uint8List.fromList(utf8.encode('{"type":"test"}'));

      final sigFromRaw = await signer.sign(rawBytes);
      final sigFromJson = await signer.sign(jsonBytes);

      final rawOverJson = await signer.verify(jsonBytes, sigFromRaw, identity.peerId);
      expect(rawOverJson, isFalse);

      final jsonOverRaw = await signer.verify(rawBytes, sigFromJson, identity.peerId);
      expect(jsonOverRaw, isFalse);
    });
  });
}
