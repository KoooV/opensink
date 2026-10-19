import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

void main() {
  group('GroupSecret', () {
    test('derive produces three independent keys', () async {
      final secret = await GroupSecret.random();
      final keys = await secret.allKeys();

      expect(keys.topic, hasLength(32));
      expect(keys.topicHex, hasLength(64));
      // signalingPayloadKey and invitationKey are SecretKey, compare extracted bytes
      final sigKeyBytes = await keys.signalingPayloadKey.extractBytes();
      final invKeyBytes = await keys.invitationKey.extractBytes();
      expect(sigKeyBytes, hasLength(32));
      expect(invKeyBytes, hasLength(32));
      expect(sigKeyBytes, isNot(equals(invKeyBytes)));
      expect(sigKeyBytes, isNot(equals(keys.topic)));
      expect(invKeyBytes, isNot(equals(keys.topic)));
    });

    test('same group_secret produces same keys (deterministic)', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final secret = GroupSecret(
        SecretKey(Uint8List.fromList(_hexToBytes(secretHex))),
      );

      final keys1 = await secret.allKeys();
      final keys2 = await secret.allKeys();

      expect(keys1.topic, equals(keys2.topic));
      expect(keys1.topicHex, equals(keys2.topicHex));
    });

    test('topicHex is hex encoding of topic', () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final secret = GroupSecret(
        SecretKey(Uint8List.fromList(_hexToBytes(secretHex))),
      );

      final topic = await secret.topic();
      final topicHex = await secret.topicHex();
      expect(topicHex, equals(bytesToHex(topic)));
    });
  });
}

List<int> _hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}
