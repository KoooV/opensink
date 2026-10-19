import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

void main() {
  group('Hkdf', () {
    test('derive produces different keys for different info', () async {
      final hkdf = Hkdf();
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final secret = SecretKey.fromBytes(
        Uint8List.fromList(
          _hexToBytes(secretHex),
        ),
      );
      const saltHex = '000102030405060708090a0b0c0d0e0f';
      final salt = Uint8List.fromList(_hexToBytes(saltHex));

      final key1 = await hkdf.deriveBytes(
        secret: secret,
        salt: salt,
        info: Uint8List.fromList(utf8.encode('context-1')),
        length: 32,
      );
      final key2 = await hkdf.deriveBytes(
        secret: secret,
        salt: salt,
        info: Uint8List.fromList(utf8.encode('context-2')),
        length: 32,
      );

      expect(key1, isNot(equals(key2)));
    });

    test('same inputs produce same output (deterministic)', () async {
      final hkdf = Hkdf();
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final secret = SecretKey.fromBytes(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );
      final salt = Uint8List.fromList(_hexToBytes('000102030405060708090a0b0c0d0e0f'));
      final info = Uint8List.fromList(utf8.encode('deterministic-test'));

      final key1 = await hkdf.deriveBytes(
        secret: secret,
        salt: salt,
        info: info,
        length: 32,
      );
      final key2 = await hkdf.deriveBytes(
        secret: secret,
        salt: salt,
        info: info,
        length: 32,
      );

      expect(key1, equals(key2));
    });

    test('different salt produces different output', () async {
      final hkdf = Hkdf();
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final secret = SecretKey.fromBytes(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );
      final info = Uint8List.fromList(utf8.encode('same-info'));

      final key1 = await hkdf.deriveBytes(
        secret: secret,
        salt: Uint8List.fromList(_hexToBytes('000102030405060708090a0b0c0d0e0f')),
        info: info,
        length: 32,
      );
      final key2 = await hkdf.deriveBytes(
        secret: secret,
        salt: Uint8List.fromList(_hexToBytes('ffeeddccbbaa99887766554433221100')),
        info: info,
        length: 32,
      );

      expect(key1, isNot(equals(key2)));
    });
  });
}

List<int> _hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}
