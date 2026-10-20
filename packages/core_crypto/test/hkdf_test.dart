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
  group('GroupHkdf (HKDF-SHA-256, RFC 5869)', () {
    // Источник: RFC 5869, Appendix A — Test Vectors
    // https://www.rfc-editor.org/rfc/rfc5869.txt (раздел Appendix A)

    /// Test Case 1: Basic test case with SHA-256 (RFC 5869 §A.1)
    ///
    /// Hash = SHA-256
    /// IKM  = 0x0b0b...0b (22 octets)
    /// salt = 0x000102030405060708090a0b0c (13 octets)
    /// info = 0xf0f1f2f3f4f5f6f7f8f9 (10 octets)
    /// L    = 42
    /// OKM  = 3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865
    test('RFC 5869 §A.1 Test Case 1: IKM=0x0b×22, salt=13 bytes, info=10 bytes, L=42',
        () async {
      final hkdf = GroupHkdf();
      final ikm = Uint8List.fromList(List<int>.filled(22, 0x0b));
      final salt = hexToBytes('000102030405060708090a0b0c');
      final info = hexToBytes('f0f1f2f3f4f5f6f7f8f9');

      final okm = await hkdf.deriveBytes(
        secret: SecretKey(ikm),
        salt: Uint8List.fromList(salt),
        info: Uint8List.fromList(info),
        length: 42,
      );

      expect(
        bytesToHex(okm),
        equals('3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
            '34007208d5b887185865'),
        reason: 'OKM must match RFC 5869 §A.1 expected output (42 octets)',
      );
      expect(okm, hasLength(42));
    });

    /// Test Case 2: Test with SHA-256 and longer inputs/outputs (RFC 5869 §A.2)
    ///
    /// Hash = SHA-256
    /// IKM  = 0x000102...4e4f (80 octets)
    /// salt = 0x606162...aeaf (80 octets)
    /// info = 0xb0b1b2...feff (80 octets)
    /// L    = 82
    /// OKM  = b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87
    test('RFC 5869 §A.2 Test Case 2: long IKM/salt/info (80 octets each), L=82',
        () async {
      final hkdf = GroupHkdf();
      final ikm = hexToBytes(
        '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f'
        '202122232425262728292a2b2c2d2e2f'
        '303132333435363738393a3b3c3d3e3f'
        '404142434445464748494a4b4c4d4e4f',
      );
      final salt = hexToBytes(
        '606162636465666768696a6b6c6d6e6f'
        '707172737475767778797a7b7c7d7e7f'
        '808182838485868788898a8b8c8d8e8f'
        '909192939495969798999a9b9c9d9e9f'
        'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf',
      );
      final info = hexToBytes(
        'b0b1b2b3b4b5b6b7b8b9babbbcbdbebf'
        'c0c1c2c3c4c5c6c7c8c9cacbcccdcecf'
        'd0d1d2d3d4d5d6d7d8d9dadbdcdddedf'
        'e0e1e2e3e4e5e6e7e8e9eaebecedeeef'
        'f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff',
      );

      final okm = await hkdf.deriveBytes(
        secret: SecretKey(ikm),
        salt: Uint8List.fromList(salt),
        info: Uint8List.fromList(info),
        length: 82,
      );

      expect(
        bytesToHex(okm),
        equals('b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c'
            '59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71'
            'cc30c58179ec3e87c14c01d5c1f3434f1d87'),
        reason: 'OKM must match RFC 5869 §A.2 expected output (82 octets)',
      );
      expect(okm, hasLength(82));
    });

    /// Test Case 3: Test with SHA-256 and zero-length salt/info (RFC 5869 §A.3)
    ///
    /// Hash = SHA-256
    /// IKM  = 0x0b0b...0b (22 octets)
    /// salt = (0 octets)
    /// info = (0 octets)
    /// L    = 42
    /// OKM  = 8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8
    test('RFC 5869 §A.3 Test Case 3: IKM=0x0b×22, empty salt/info, L=42',
        () async {
      final hkdf = GroupHkdf();
      final ikm = Uint8List.fromList(List<int>.filled(22, 0x0b));
      final salt = Uint8List(0);
      final info = Uint8List(0);

      final okm = await hkdf.deriveBytes(
        secret: SecretKey(ikm),
        salt: Uint8List.fromList(salt),
        info: Uint8List.fromList(info),
        length: 42,
      );

      expect(
        bytesToHex(okm),
        equals('8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d'
            '9d201395faa4b61a96c8'),
        reason: 'OKM must match RFC 5869 §A.3 expected output (42 octets)',
      );
      expect(okm, hasLength(42));
    });

    test('same inputs produce same output (deterministic)', () async {
      final hkdf = GroupHkdf();
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final secret = SecretKey(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );
      final salt = Uint8List.fromList(_hexToBytes('000102030405060708090a0b0c0d0e0f'));
      final info = Uint8List.fromList(utf8.encode('deterministic-test'));

      final key1 = await hkdf.deriveBytes(
        secret: secret, salt: Uint8List.fromList(salt), info: Uint8List.fromList(info), length: 32,
      );
      final key2 = await hkdf.deriveBytes(
        secret: secret, salt: Uint8List.fromList(salt), info: Uint8List.fromList(info), length: 32,
      );

      expect(key1, equals(key2));
    });

    test('different info produces different output', () async {
      final hkdf = GroupHkdf();
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final secret = SecretKey(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );
      final salt = Uint8List.fromList(_hexToBytes('000102030405060708090a0b0c0d0e0f'));

      final key1 = await hkdf.deriveBytes(
        secret: secret, salt: Uint8List.fromList(salt), info: Uint8List.fromList(utf8.encode('context-1')), length: 32,
      );
      final key2 = await hkdf.deriveBytes(
        secret: secret, salt: Uint8List.fromList(salt), info: Uint8List.fromList(utf8.encode('context-2')), length: 32,
      );

      expect(key1, isNot(equals(key2)));
    });

    test('different salt produces different output', () async {
      final hkdf = GroupHkdf();
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final secret = SecretKey(
        Uint8List.fromList(_hexToBytes(secretHex)),
      );
      final info = Uint8List.fromList(utf8.encode('same-info'));

      final key1 = await hkdf.deriveBytes(
        secret: secret, salt: Uint8List.fromList(_hexToBytes('000102030405060708090a0b0c0d0e0f')), info: Uint8List.fromList(info), length: 32,
      );
      final key2 = await hkdf.deriveBytes(
        secret: secret, salt: Uint8List.fromList(_hexToBytes('ffeeddccbbaa99887766554433221100')), info: Uint8List.fromList(info), length: 32,
      );

      expect(key1, isNot(equals(key2)));
    });
  });

  group('GroupKeyContext enum', () {
    test('signalingTopic info contains version', () {
      expect(
        utf8.decode(GroupKeyContext.signalingTopic.info),
        equals('opensink/group/signaling-topic'),
      );
    });

    test('signalingPayloadKey info contains version', () {
      expect(
        utf8.decode(GroupKeyContext.signalingPayloadKey.info),
        equals('opensink/group/signaling-payload-key'),
      );
    });

    test('invitationKey info contains version', () {
      expect(
        utf8.decode(GroupKeyContext.invitationKey.info),
        equals('opensink/group/invitation-key'),
      );
    });

    test('contexts are distinct', () {
      expect(GroupKeyContext.signalingTopic, isNot(GroupKeyContext.signalingPayloadKey));
      expect(GroupKeyContext.signalingPayloadKey, isNot(GroupKeyContext.invitationKey));
      expect(GroupKeyContext.signalingTopic, isNot(GroupKeyContext.invitationKey));
    });
  });
}

List<int> _hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}
