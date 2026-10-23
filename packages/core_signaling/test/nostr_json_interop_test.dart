@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:core_signaling/core_signaling.dart';
import 'package:test/test.dart';

/// Сверяет каноническую сериализацию NIP-01 с эталонным V8
/// `JSON.stringify` через Node.js. Если Node недоступен — тест пропускается.
void main() {
  test('NIP-01 serialization matches V8 JSON.stringify', () async {
    const script = '''
const crypto = require('crypto');
const event = JSON.parse(Buffer.from(process.env.PAYLOAD, 'base64').toString('utf8'));
const serialized = JSON.stringify([0, event.pubkey, event.created_at, event.kind, event.tags, event.content]);
const id = crypto.createHash('sha256').update(serialized, 'utf8').digest('hex');
process.stdout.write(JSON.stringify({ serialized, id }));
''';

    final cases = <NostrEvent>[
      NostrEvent(
        id: '',
        pubkey: 'a' * 64,
        createdAt: 1700000000,
        kind: 21000,
        tags: <List<String>>[
          <String>['t', 'topic\u0001hash'],
        ],
        content: 'hello\nworld',
        sig: '',
      ),
      NostrEvent(
        id: '',
        pubkey: 'b' * 64,
        createdAt: 1700000001,
        kind: 21000,
        tags: <List<String>>[
          <String>['t', 'кириллица'],
          <String>['p', 'c' * 64],
        ],
        content: 'quote " backslash \\ slash / tab\t ctrl\u0001 emoji 😀',
        sig: '',
      ),
      NostrEvent(
        id: '',
        pubkey: 'c' * 64,
        createdAt: 1700000002,
        kind: 21000,
        tags: const <List<String>>[],
        content: 'line sep \u2028 para \u2029 end \b\f\r',
        sig: '',
      ),
    ];

    for (final event in cases) {
      final payload = <String, Object?>{
        'pubkey': event.pubkey,
        'created_at': event.createdAt,
        'kind': event.kind,
        'tags': event.tags,
        'content': event.content,
      };
      final ProcessResult result;
      try {
        result = await Process.run(
          'node',
          <String>['-e', script],
          environment: <String, String>{
            'PAYLOAD': base64Encode(utf8.encode(jsonEncode(payload))),
          },
        );
      } on ProcessException {
        markTestSkipped('Node.js is not available for JSON.stringify interop');
        return;
      }
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final decoded =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(decoded['serialized'], event.serializationForId());
      expect(decoded['id'], event.computeId());
    }
  });
}
