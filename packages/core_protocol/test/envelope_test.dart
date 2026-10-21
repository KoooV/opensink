import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_domain/core_domain.dart' hide GroupEvent, RelayFrame;
import 'package:core_protocol/core_protocol.dart';

final _sender = Uint8List.fromList([1, 2, 3]);
final _codec = ProtocolCodec();

Envelope _makeEnvelope({
  required Uint8List sender,
  int version = 1,
  MessageType type = MessageType.chatEvent,
  int hlc = 1000,
  Uint8List? payload,
  Uint8List? signature,
  Map<int, Uint8List>? unknownFields,
}) {
  return Envelope(
    version: version,
    type: type,
    sender: sender,
    hlc: hlc,
    payload: payload ?? Uint8List(0),
    signature: signature ?? Uint8List(0),
      unknownFields: unknownFields ?? const {},
    );
  }

  void main() {
  group('Envelope roundtrip (all message types)', () {
    test('ChatEvent', () {
      final message = ChatEvent(
        id: 'evt-1',
        groupId: 'group-a',
        channelId: 'chan-general',
        authorId: 'user-alice',
        timestamp: 1700000000000,
        text: 'hello, world',
        replyTo: 'evt-0',
        attachments: [Uint8List.fromList([1, 2, 3])],
      );
      expect(ChatEvent.fromBytes(message.toBytes()), message);
    });

    test('GroupEvent', () {
      final message = GroupEvent(
        id: 'gev-1',
        groupId: 'group-a',
        authorId: 'user-alice',
        timestamp: 1700000001000,
        signature: '0123456789abcdef',
        eventType: 1,
        name: 'My Group',
        ownerId: 'user-alice',
        initialMembers: const ['user-alice', 'user-bob'],
      );
      expect(GroupEvent.fromBytes(message.toBytes()), message);
    });

    test('SyncRequest', () {
      final message = SyncRequest(
        requester: 'peer-hex-alice',
        sinceEventId: 'evt-100',
        sinceHlc: 5000,
        limit: 50,
        groupIds: const ['group-a', 'group-b'],
      );
      expect(SyncRequest.fromBytes(message.toBytes()), message);
    });

    test('SyncResponse', () {
      final message = SyncResponse(
        responder: 'peer-hex-bob',
        events: [Uint8List.fromList([1, 2]), Uint8List.fromList([3, 4])],
        checkpoint: 'evt-200',
        more: true,
      );
      expect(SyncResponse.fromBytes(message.toBytes()), message);
    });

    test('FileChunk', () {
      final message = FileChunk(
        fileId: 'file-1',
        chunkIndex: 2,
        totalChunks: 5,
        data: Uint8List.fromList([10, 20, 30]),
        totalSize: 1000,
        sha256: Uint8List.fromList([9, 8, 7]),
        chunkHash: Uint8List.fromList([1, 2]),
      );
      expect(FileChunk.fromBytes(message.toBytes()), message);
    });

    test('FileRequest', () {
      final message = FileRequest(
        fileId: 'file-1',
        chunkIndex: 2,
        size: 256000,
      );
      expect(FileRequest.fromBytes(message.toBytes()), message);
    });

    test('Presence', () {
      final message = Presence(
        peerId: 'peer-hex-carol',
        status: 'dnd',
        lastSeen: 1700000002000,
        capabilities: const ['video', 'screen-share'],
      );
      expect(Presence.fromBytes(message.toBytes()), message);
    });

    test('CallControl', () {
      final message = CallControl(
        callId: 'call-1',
        callType: CallControlType.offer,
        sdp: 'v=0\r\n',
        candidate: 'candidate:1 1 udp 2113937153',
        sdpMid: 'video',
        sdpMLineIndex: 0,
      );
      expect(CallControl.fromBytes(message.toBytes()), message);
    });

    test('RelayFrame', () {
      final message = RelayFrame(
        dst: Uint8List.fromList([4, 5, 6]),
        src: Uint8List.fromList([1, 2, 3]),
        ttl: 7,
        hopCount: 1,
        payload: Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]),
      );
      expect(RelayFrame.fromBytes(message.toBytes()), message);
    });

    test('LeaderLease', () {
      final message = LeaderLease(
        groupId: 'group-a',
        leaderId: 'peer-hex-alice',
        term: 3,
        expiresAt: 1700000010000,
        sequence: 42,
      );
      expect(LeaderLease.fromBytes(message.toBytes()), message);
    });

    test('envelope wrap/unwrap preserves payload and type', () {
      final payload = ChatEvent(
        id: 'x', groupId: 'g', channelId: 'c', authorId: 'a', timestamp: 1,
      ).toBytes();
      final envelope = _makeEnvelope(sender: _sender, payload: payload);
      final encoded = envelope.toBytes();
      final decoded = Envelope.fromBytes(encoded);
      expect(decoded.payload, payload);
      expect(decoded.type, MessageType.chatEvent);
      expect(decoded.hlc, 1000);
    });
  });

  group('golden', () {
    test('encoded envelope matches golden bytes from file', () async {
      final goldenFile = File('test/testdata/envelope_v1_chat_event.golden');
      final goldenBytes = await goldenFile.readAsBytes();
      final envelope = _makeEnvelope(
        sender: _sender,
        payload: Uint8List.fromList([10, 11]),
      );
      expect(envelope.toBytes(), goldenBytes);
      final decoded = Envelope.fromBytes(goldenBytes);
      expect(decoded, envelope);
      expect(decoded.unknownFields, isEmpty);
    });
  });

  group('unknown fields and types (forward compatibility)', () {
    test('unknown field is preserved and forwarded', () {
      final writer = ProtoWriter();
      writer.writeVarintField(1, 1); // version
      writer.writeVarintField(2, 1); // type
      writer.writeBytesField(3, _sender);
      writer.writeVarintField(4, 1000); // hlc
      writer.writeBytesField(5, Uint8List.fromList([10, 11])); // payload
      // Unknown field 100 = varint 42: tag (100 << 3) | 0 = 800.
      writer.writeVarint(800);
      writer.writeVarint(42);
      final raw = writer.finish();

      final decoded = Envelope.fromBytes(raw);
      expect(decoded.version, 1);
      expect(decoded.type.value, 1);
      expect(decoded.sender, _sender);
      expect(decoded.hlc, 1000);
      expect(decoded.payload, Uint8List.fromList([10, 11]));
      expect(decoded.unknownFields.containsKey(100), isTrue);
      expect(decoded.unknownFields[100], Uint8List.fromList([0xA0, 0x06, 0x2A]));

      final reDecoded = Envelope.fromBytes(decoded.toBytes());
      expect(reDecoded.unknownFields[100], decoded.unknownFields[100]);
    });

    test('unknown message type decodes structurally and is reported', () {
      final envelope = _makeEnvelope(
        sender: _sender,
        type: MessageType.fromInt(99),
      );
      final encoded = envelope.toBytes();
      final decoded = Envelope.fromBytes(encoded);
      expect(decoded.type.value, 99);
      expect(decoded.payload, Uint8List(0));

      final result = _codec.decodePayload(decoded);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<UnknownMessageType>());
    });

    test('empty input decode returns Err without throwing', () {
      expect(() => _codec.decode(Uint8List(0)), returnsNormally);
      expect(_codec.decode(Uint8List(0)).isErr, isTrue);
    });
  });

  group('signature zone and unknown fields', () {
    test('signatureData does not cover unknown fields', () {
      final base = _makeEnvelope(
        sender: _sender,
        payload: Uint8List.fromList([10, 11]),
      );
      final withUnknown = _makeEnvelope(
        sender: _sender,
        payload: Uint8List.fromList([10, 11]),
        unknownFields: {100: Uint8List.fromList([1, 2, 3])},
      );
      // Подписываемые данные идентичны независимо от неизвестных полей.
      expect(base.signatureData(), withUnknown.signatureData());
    });

    test('unknown field can be injected after signing and signature still verifies', () async {
      final sender = PeerId(Uint8List.fromList([1, 2, 3]));
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1, 2, 3]),
        hlc: 1,
        payload: Uint8List.fromList([9, 9]),
        signature: Uint8List(0),
      );
      final signer = FakeSignerProtocol(sender);
      final signed = (await ProtocolCodec().sign(envelope, signer, senderPeerId: sender)).unwrap();
      // Инъекция неизвестного поля после подписи.
      final injected = signed.copyWith(
        unknownFields: {200: Uint8List.fromList([0xDE, 0xAD])},
      );
      final verified = await ProtocolCodec().verify(injected, signer, sender);
      expect(verified.isOk, isTrue);
      expect(verified.unwrap(), isTrue);
    });

    test('isProcessable true for current version, false for future', () {
      expect(Envelope(version: 1, type: MessageType.chatEvent, sender: _sender, hlc: 1, payload: Uint8List(0), signature: Uint8List(0)).isProcessable, isTrue);
      expect(Envelope(version: 999, type: MessageType.chatEvent, sender: _sender, hlc: 1, payload: Uint8List(0), signature: Uint8List(0)).isProcessable, isFalse);
    });
  });
}

// Вспомогательный фейковый签署ватель для тестов зоны подписи.
class FakeSignerProtocol implements Signer {
  FakeSignerProtocol(this.peerId);

  final PeerId peerId;

  @override
  Future<String> sign(Uint8List data) async => _hexProtocol(data);

  @override
  Future<bool> verify(Uint8List data, String signatureHex, PeerId p) async {
    return signatureHex == _hexProtocol(data) && _bytesProtocol(p.publicKey, peerId.publicKey);
  }
}

String _hexProtocol(Uint8List bytes) {
  const chars = '0123456789abcdef';
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(chars[(b >> 4) & 0xF]);
    buf.write(chars[b & 0xF]);
  }
  return buf.toString();
}

bool _bytesProtocol(Uint8List? a, Uint8List? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
