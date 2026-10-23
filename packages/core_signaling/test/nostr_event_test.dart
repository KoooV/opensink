@TestOn('vm')
library;

import 'dart:convert';

import 'package:core_signaling/core_signaling.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';

void main() {
  group('NIP-01 NostrEvent', () {
    test('computes id and BIP-340 signature', () {
      final signer = NostrEphemeralSigner.fromPrivateKeyHex(
        '0000000000000000000000000000000000000000000000000000000000000001',
      );
      expect(
        signer.publicKeyHex,
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
      );

      final event = signer.sign(
        kind: NostrSignaling.ephemeralKind,
        tags: <List<String>>[
          <String>['t', 'topic-hash'],
        ],
        content: 'hello\nworld',
        createdAt: 1700000000,
      );
      expect(event, isNotNull);
      final signed = event!;
      expect(signed.id, hasLength(64));
      expect(signed.sig, hasLength(128));
      expect(signed.hasValidId(), isTrue);
      expect(signed.hasValidSignature(), isTrue);
      expect(signer.verify(signed), isTrue);

      final json = jsonDecode(jsonEncode(signed.toJson()));
      final parsed = NostrEvent.fromJson(json);
      expect(parsed, isNotNull);
      expect(parsed!.id, signed.id);
      expect(parsed.hasValidId(), isTrue);
      expect(parsed.hasValidSignature(), isTrue);
    });

    test('id uses NIP-01 canonical array serialization', () {
      final event = NostrEvent(
        id: '',
        pubkey: 'a' * 64,
        createdAt: 1,
        kind: 21000,
        tags: <List<String>>[
          <String>['t', 'b'],
        ],
        content: 'c',
        sig: '',
      );
      final expected = jsonEncode(<Object?>[
        0,
        'a' * 64,
        1,
        21000,
        <List<String>>[
          <String>['t', 'b'],
        ],
        'c',
      ]);
      expect(event.serializationForId(), expected);
      expect(
        event.computeId(),
        crypto.sha256.convert(utf8.encode(expected)).toString(),
      );
    });

    test('detects tampered content and malformed json', () {
      final signer = NostrEphemeralSigner.fromPrivateKeyHex(
        '0000000000000000000000000000000000000000000000000000000000000001',
      );
      final event = signer.sign(
        kind: 21000,
        tags: const <List<String>>[],
        content: 'original',
        createdAt: 1700000000,
      )!;
      final tampered = NostrEvent(
        id: event.id,
        pubkey: event.pubkey,
        createdAt: event.createdAt,
        kind: event.kind,
        tags: event.tags,
        content: 'tampered',
        sig: event.sig,
      );
      expect(tampered.hasValidId(), isFalse);
      expect(tampered.hasValidSignature(), isTrue);
      expect(tampered.hasValidId() && tampered.hasValidSignature(), isFalse);

      expect(NostrEvent.fromJson(<String, Object?>{'id': 1}), isNull);
      expect(NostrEvent.fromJson('not-a-map'), isNull);
      expect(
        NostrEvent.fromJson(<String, Object?>{
          'id': 'x',
          'pubkey': 'y',
          'created_at': 'z',
          'kind': 1,
          'tags': <Object?>[],
          'content': '',
          'sig': '',
        }),
        isNull,
      );
    });

    test('ephemeral keys are unique', () {
      final first = NostrEphemeralSigner.generate();
      final second = NostrEphemeralSigner.generate();
      expect(first.privateKeyHex, isNot(second.privateKeyHex));
      expect(first.publicKeyHex, hasLength(64));
    });
  });
}
