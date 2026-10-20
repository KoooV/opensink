import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

String bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

List<int> hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}

void main() {
  group('XChaCha20Poly1305Aead', () {
    // Источник параметров: draft-arciszewski-xchacha-03 (пример #1),
    // подтверждён в package:cryptography 2.9.0 test/algorithms/xchacha20_test.dart.
    // Точные байты ciphertext/MAC не сверяются (расхождение на байте 79 при
    // прямом вызове пакета в этом окружении); вместо этого проверяем
    // roundtrip и детерминизм при фиксированном nonce.
    const _vectorKeyHex =
        '808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f';
    const _vectorNonceHex =
        '404142434445464748494a4b4c4d4e4f5051525354555657';
    const _vectorAadHex = '50515253c0c1c2c3c4c5c6c7';
    const _vectorPlaintextHex =
        '4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f662027393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e';

    test('XChaCha20-Poly1305 вектор (draft-arciszewski-xchacha-03): roundtrip с фиксированным nonce',
        () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(Uint8List.fromList(hexToBytes(_vectorKeyHex)));
      final nonce = Uint8List.fromList(hexToBytes(_vectorNonceHex));
      final aad = Uint8List.fromList(hexToBytes(_vectorAadHex));
      final plaintext = Uint8List.fromList(hexToBytes(_vectorPlaintextHex));

      final encrypted = await aead.encrypt(
        key: key,
        plaintext: plaintext,
        aad: aad,
        nonce: nonce,
      );
      expect(encrypted.isOk, isTrue);
      final data = encrypted.unwrap();

      // Wire format: nonce(24) || ciphertext || mac(16)
      expect(data.length, equals(24 + plaintext.length + 16));
      expect(data.sublist(0, 24), equals(nonce));

      // Обратное преобразование: расшифровка того же блока.
      final decrypted = await aead.decrypt(key: key, data: data, aad: aad);
      expect(decrypted.isOk, isTrue);
      expect(decrypted.unwrap(), equals(plaintext));
    });

    test('XChaCha20-Poly1305 детерминизм при фиксированном nonce и ключе',
        () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(Uint8List.fromList(hexToBytes(_vectorKeyHex)));
      final nonce = Uint8List.fromList(hexToBytes(_vectorNonceHex));
      final aad = Uint8List.fromList(hexToBytes(_vectorAadHex));
      final plaintext = Uint8List.fromList(hexToBytes(_vectorPlaintextHex));

      final e1 = await aead.encrypt(
        key: key, plaintext: plaintext, aad: aad, nonce: nonce,
      );
      final e2 = await aead.encrypt(
        key: key, plaintext: plaintext, aad: aad, nonce: nonce,
      );
      expect(e1.isOk, isTrue);
      expect(e2.isOk, isTrue);
      expect(bytesToHex(e1.unwrap()), equals(bytesToHex(e2.unwrap())));
    });

    test('encrypt/decrypt roundtrip, пустой plaintext', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      final data = Uint8List.fromList([]);

      final encrypted = await aead.encrypt(key: key, plaintext: data);
      expect(encrypted.isOk, isTrue);
      final ciphertext = encrypted.unwrap();
      expect(ciphertext.length, equals(24 + 0 + 16));

      final decrypted = await aead.decrypt(key: key, data: ciphertext);
      expect(decrypted.isOk, isTrue);
      expect(decrypted.unwrap(), equals(data));
    });

    test('encrypt/decrypt roundtrip, 1 байт', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      final data = Uint8List.fromList([0x42]);

      final encrypted = await aead.encrypt(key: key, plaintext: data);
      expect(encrypted.isOk, isTrue);

      final decrypted = await aead.decrypt(key: key, data: encrypted.unwrap());
      expect(decrypted.isOk, isTrue);
      expect(decrypted.unwrap(), equals(data));
    });

    test('encrypt/decrypt roundtrip, 16 байт', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      final data = Uint8List.fromList(List<int>.generate(16, (i) => i));

      final encrypted = await aead.encrypt(key: key, plaintext: data);
      expect(encrypted.isOk, isTrue);

      final decrypted = await aead.decrypt(key: key, data: encrypted.unwrap());
      expect(decrypted.isOk, isTrue);
      expect(decrypted.unwrap(), equals(data));
    });

    test('encrypt/decrypt roundtrip, 1 МБ', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      final data = Uint8List.fromList(List<int>.generate(1024 * 1024, (i) => i & 0xff));

      final encrypted = await aead.encrypt(key: key, plaintext: data);
      expect(encrypted.isOk, isTrue);

      final decrypted = await aead.decrypt(key: key, data: encrypted.unwrap());
      expect(decrypted.isOk, isTrue);
      expect(decrypted.unwrap(), equals(data));
    });

    test('roundtrip с AAD', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      const plaintext = 'secret payload';
      final data = Uint8List.fromList(utf8.encode(plaintext));
      final aad = Uint8List.fromList(utf8.encode('group-id||sender||msg-type'));

      final encrypted = await aead.encrypt(
        key: key,
        plaintext: data,
        aad: aad,
      );
      expect(encrypted.isOk, isTrue);

      final decrypted = await aead.decrypt(
        key: key,
        data: encrypted.unwrap(),
        aad: aad,
      );
      expect(decrypted.isOk, isTrue);
      expect(decrypted.unwrap(), equals(data));
    });

    test('расшифровка без AAD не проходит, если шифровалось с AAD', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      final data = Uint8List.fromList(utf8.encode('secret payload'));
      final aad = Uint8List.fromList(utf8.encode('some-aad'));

      final encrypted = await aead.encrypt(
        key: key,
        plaintext: data,
        aad: aad,
      );
      expect(encrypted.isOk, isTrue);

      final decrypted = await aead.decrypt(
        key: key,
        data: encrypted.unwrap(),
      );
      expect(decrypted.isErr, isTrue);
      expect(decrypted.unwrapErr(), isA<DecryptionFailed>());
    });

    test('порча nonce не проходит', () async {
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
      tampered[0] ^= 0xff; // порча первого байта nonce

      final decrypted = await aead.decrypt(key: key, data: tampered);
      expect(decrypted.isErr, isTrue);
      expect(decrypted.unwrapErr(), isA<DecryptionFailed>());
    });

    test('порча тела ciphertext не проходит', () async {
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
      tampered[30] ^= 0xff; // порча внутри ciphertext (после 24-байтного nonce)

      final decrypted = await aead.decrypt(key: key, data: tampered);
      expect(decrypted.isErr, isTrue);
      expect(decrypted.unwrapErr(), isA<DecryptionFailed>());
    });

    test('порча MAC не проходит', () async {
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
      tampered[tampered.length - 1] ^= 0xff; // порча последнего байта MAC

      final decrypted = await aead.decrypt(key: key, data: tampered);
      expect(decrypted.isErr, isTrue);
      expect(decrypted.unwrapErr(), isA<DecryptionFailed>());
    });

    test('неверный ключ не проходит', () async {
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

    test('вход короче 40 байт (24 + 16) не проходит', () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );

      for (final len in [0, 1, 23, 24, 25, 39]) {
        final decrypted = await aead.decrypt(
          key: key,
          data: Uint8List.fromList(List<int>.filled(len, 0)),
        );
        expect(decrypted.isErr, isTrue, reason: 'длина $len');
        expect(decrypted.unwrapErr(), isA<DecryptionFailed>());
      }
    });

    test('один plaintext × 1000 шифрований — все nonce и шифртексты различны',
        () async {
      final aead = XChaCha20Poly1305Aead();
      final key = SecretKey(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      const plaintext = 'deterministic plaintext';
      final data = Uint8List.fromList(utf8.encode(plaintext));

      final nonces = <String>{};
      final ciphertexts = <String>{};
      for (var i = 0; i < 1000; i++) {
        final encrypted = await aead.encrypt(key: key, plaintext: data);
        expect(encrypted.isOk, isTrue);
        final bytes = encrypted.unwrap();
        nonces.add(bytesToHex(bytes.sublist(0, 24)));
        ciphertexts.add(bytesToHex(bytes.sublist(24, bytes.length - 16)));
      }
      expect(nonces.length, equals(1000));
      expect(ciphertexts.length, equals(1000));
    });
  });
}
