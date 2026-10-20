import 'dart:convert';
import 'dart:math';
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
  group('GroupSecret', () {
    const fixedSecretHex = '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f';

    test('topic, signalingPayloadKey, invitationKey детерминированы для одного секрета',
        () async {
      final secret = GroupSecret(
        SecretKey(Uint8List.fromList(hexToBytes(fixedSecretHex))),
      );

      final keys1 = await secret.allKeys();
      final keys2 = await secret.allKeys();

      expect(keys1.topic, equals(keys2.topic));
      expect(keys1.topicHex, equals(keys2.topicHex));
      final sig1 = await keys1.signalingPayloadKey.extractBytes();
      final sig2 = await keys2.signalingPayloadKey.extractBytes();
      final inv1 = await keys1.invitationKey.extractBytes();
      final inv2 = await keys2.invitationKey.extractBytes();
      expect(sig1, equals(sig2));
      expect(inv1, equals(inv2));
    });

    test('topic, signalingPayloadKey, invitationKey попарно различны', () async {
      final secret = GroupSecret(
        SecretKey(Uint8List.fromList(hexToBytes(fixedSecretHex))),
      );
      final keys = await secret.allKeys();

      final sigBytes = await keys.signalingPayloadKey.extractBytes();
      final invBytes = await keys.invitationKey.extractBytes();

      expect(keys.topic, hasLength(32));
      expect(keys.topicHex, hasLength(64));
      expect(sigBytes, hasLength(32));
      expect(invBytes, hasLength(32));
      expect(sigBytes, isNot(equals(keys.topic)));
      expect(invBytes, isNot(equals(keys.topic)));
      expect(sigBytes, isNot(equals(invBytes)));
    });

    test('разные секреты → разные topic (1000 случайных, без коллизий)', () async {
      final random = Random.secure();
      final topics = <String>{};
      for (var i = 0; i < 1000; i++) {
        final entropy = Uint8List.fromList(
          List<int>.generate(32, (_) => random.nextInt(256)),
        );
        final secret = GroupSecret(SecretKey(entropy));
        final topic = await secret.topic();
        topics.add(bytesToHex(topic));
      }
      expect(topics.length, equals(1000), reason: 'нет коллизий topic на 1000 секретах');
    });

    test('topicHex = hex(topic)', () async {
      final secret = GroupSecret(
        SecretKey(Uint8List.fromList(hexToBytes(fixedSecretHex))),
      );
      final topic = await secret.topic();
      final topicHex = await secret.topicHex();
      expect(topicHex, equals(bytesToHex(topic)));
    });

    test('GroupSecret.allKeys возвращает ключи правильной длины', () async {
      final secret = GroupSecret(
        SecretKey(Uint8List.fromList(hexToBytes(fixedSecretHex))),
      );
      final keys = await secret.allKeys();

      expect(keys.topic, hasLength(32));
      final sigBytes = await keys.signalingPayloadKey.extractBytes();
      final invBytes = await keys.invitationKey.extractBytes();
      expect(sigBytes, hasLength(32));
      expect(invBytes, hasLength(32));
    });

    test('GroupSecret.toString не раскрывает секрет', () async {
      final secret = GroupSecret(
        SecretKey(Uint8List.fromList(hexToBytes(fixedSecretHex))),
      );

      final str = secret.toString();

      expect(str, equals('GroupSecret(<secret>)'));
    });

    test('GroupKeys.toString не раскрывает ключи', () async {
      final secret = GroupSecret(
        SecretKey(Uint8List.fromList(hexToBytes(fixedSecretHex))),
      );
      final keys = await secret.allKeys();

      final str = keys.toString();

      expect(str, contains(keys.topicHex));
      expect(str, contains('<secret>'));
      expect(str, isNot(contains('SecretKey')));
    });

    test('GroupSecret.random создаёт секрет с 32-байтным ключом', () async {
      final secret = await GroupSecret.random();
      final keys = await secret.allKeys();
      final sigBytes = await keys.signalingPayloadKey.extractBytes();
      expect(sigBytes, hasLength(32));
    });

    test('GroupSecret.random ключи детерминированы для того же секрета (если передан в конструктор)',
        () async {
      const secretHex = '000102030405060708090a0b0c0d0e0f'
          '101112131415161718191a1b1c1d1e1f';
      final s1 = GroupSecret(SecretKey(Uint8List.fromList(hexToBytes(secretHex))));
      final s2 = GroupSecret(SecretKey(Uint8List.fromList(hexToBytes(secretHex))));

      final k1 = await s1.allKeys();
      final k2 = await s2.allKeys();
      expect(k1.topicHex, equals(k2.topicHex));
    });
  });
}
