import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/test_signer.dart';

void main() {
  group('SyncEvent / codec', () {
    final author = testAuthor(0);
    final signer = TestSigner(author.value);
    const group = GroupId('g');
    const channel = ChannelId('c');

    test('id is content hash and includes HLC, author, prev', () async {
      final a = await signedEvent(
        signer: signer,
        author: author,
        groupId: group,
        hlc: const Hlc(1000, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: Uint8List.fromList(utf8.encode('hello')),
      );
      final b = await signedEvent(
        signer: signer,
        author: author,
        groupId: group,
        hlc: const Hlc(1000, 1),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: Uint8List.fromList(utf8.encode('hello')),
      );
      final c = await signedEvent(
        signer: signer,
        author: author,
        groupId: group,
        hlc: const Hlc(1000, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: Uint8List.fromList(utf8.encode('hello')),
        prevId: a.id,
      );

      expect(a.id.value, hasLength(64));
      expect(a.id, isNot(b.id));
      expect(a.id, isNot(c.id));
    });

    test('encode/decode roundtrip preserves all fields', () async {
      final event = await signedEvent(
        signer: signer,
        author: author,
        groupId: group,
        hlc: const Hlc(1234, 2),
        kind: SyncEventKind.messageEdited,
        channelId: channel,
        targetId: 'target',
        prevId: const EventId('prev'),
        payload: Uint8List.fromList(<int>[1, 2, 3]),
      );
      const codec = SyncEventCodec();
      final encoded = codec.encode(event).unwrap();
      final decoded = codec.decode(encoded).unwrap();

      expect(decoded.id, event.id);
      expect(decoded.groupId, event.groupId);
      expect(decoded.channelId, event.channelId);
      expect(decoded.authorId, event.authorId);
      expect(decoded.hlc, event.hlc);
      expect(decoded.kind, event.kind);
      expect(decoded.targetId, event.targetId);
      expect(decoded.prevId, event.prevId);
      expect(decoded.payload, event.payload);
      expect(decoded.signature, event.signature);
      expect(decoded.computeId(), event.id.value);
      expect(decoded.signedBytes(), event.signedBytes());
    });

    test('record roundtrip preserves canonical body and signature', () async {
      final event = await signedEvent(
        signer: signer,
        author: author,
        groupId: group,
        hlc: const Hlc(50, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: Uint8List.fromList(utf8.encode('body')),
      );
      const codec = SyncEventCodec();
      final restored = codec.fromRecord(event.toRecord()).unwrap();
      expect(restored.id, event.id);
      expect(restored.payload, event.payload);
      expect(restored.signature, event.signature);
    });

    test('tampered id is rejected on decode', () async {
      final event = await signedEvent(
        signer: signer,
        author: author,
        groupId: group,
        hlc: const Hlc(1, 0),
        kind: SyncEventKind.messageCreated,
        payload: Uint8List.fromList(<int>[1]),
      );
      const codec = SyncEventCodec();
      final canonical = event.canonicalBytes();
      final result = codec.decodeCanonical(
        canonical,
        eventId: List.filled(64, '0').join(),
        signature: event.signature,
      );
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<EventIdMismatch>());
    });
  });
}
