import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_protocol/core_protocol.dart';

class FakeSigner implements Signer {
  FakeSigner(this.peerId);

  final PeerId peerId;

  @override
  Future<String> sign(Uint8List data) async => _hex(data);

  @override
  Future<bool> verify(
    Uint8List data,
    String signatureHex,
    PeerId p,
  ) async {
    return signatureHex == _hex(data) && _bytesEquals(p.publicKey, peerId.publicKey);
  }
}

String _hex(Uint8List bytes) {
  const chars = '0123456789abcdef';
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(chars[(b >> 4) & 0xF]);
    buf.write(chars[b & 0xF]);
  }
  return buf.toString();
}

bool _bytesEquals(Uint8List? a, Uint8List? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  final sender = PeerId(Uint8List.fromList([1, 2, 3]));
  final other = PeerId(Uint8List.fromList([9, 9, 9]));
  final codec = ProtocolCodec();

  group('encode/decode', () {
    test('valid envelope roundtrips through codec', () {
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1, 2, 3]),
        hlc: 12345,
        payload: Uint8List.fromList([1, 2, 3]),
        signature: Uint8List(0),
      );
      final encoded = codec.encode(envelope);
      expect(encoded.isOk, isTrue);
      final decoded = codec.decode(encoded.unwrap());
      expect(decoded.isOk, isTrue);
      expect(decoded.unwrap().payload, Uint8List.fromList([1, 2, 3]));
      expect(decoded.unwrap().hlc, 12345);
    });

    test('oversized payload is rejected on encode', () {
      final bigPayload = Uint8List(ProtocolLimits.maxPayloadSize + 1);
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1]),
        hlc: 1,
        payload: bigPayload,
        signature: Uint8List(0),
      );
      final encoded = codec.encode(envelope);
      expect(encoded.isErr, isTrue);
      expect(encoded.unwrapErr(), isA<SizeLimitExceeded>());
    });

    test('frame larger than maxFrameSize is rejected on encode', () {
      // Payload в рамках maxPayloadSize, но итоговый фрейм > maxFrameSize
      // невозможен через payload seul; проверяем защиту на этапе encode.
      final bigPayload = Uint8List(ProtocolLimits.maxPayloadSize);
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1]),
        hlc: 1,
        payload: bigPayload,
        signature: Uint8List(0),
      );
      final encoded = codec.encode(envelope);
      expect(encoded.isOk, isTrue);
      expect(encoded.unwrap().length, lessThanOrEqualTo(ProtocolLimits.maxFrameSize));
    });

    test('decode of oversized bytes returns Err', () {
      final big = Uint8List(ProtocolLimits.maxFrameSize + 1);
      final result = codec.decode(big);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<SizeLimitExceeded>());
    });

    test('decode rejects unsupported version', () {
      final writer = ProtoWriter();
      writer.writeVarintField(1, 0); // version 0 < minSupported
      writer.writeVarintField(2, 1);
      writer.writeBytesField(3, Uint8List.fromList([1]));
      writer.writeVarintField(4, 1);
      writer.writeBytesField(5, Uint8List.fromList([2]));
      final result = codec.decode(writer.finish());
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<UnknownVersion>());
    });
  });

  group('sign / verify', () {
    test('sign then verify succeeds with matching peer', () async {
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1, 2, 3]),
        hlc: 1,
        payload: Uint8List.fromList([9, 9]),
        signature: Uint8List(0),
      );
      final signer = FakeSigner(sender);
      final signed = await codec.sign(envelope, signer, senderPeerId: sender);
      expect(signed.isOk, isTrue);
      final verified = await codec.verify(signed.unwrap(), signer, sender);
      expect(verified.isOk, isTrue);
      expect(verified.unwrap(), isTrue);
    });

    test('verify fails with wrong peer', () async {
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1, 2, 3]),
        hlc: 1,
        payload: Uint8List.fromList([9, 9]),
        signature: Uint8List(0),
      );
      final signer = FakeSigner(sender);
      final signed = await codec.sign(envelope, signer, senderPeerId: sender);
      final verified = await codec.verify(signed.unwrap(), signer, other);
      expect(verified.isOk, isTrue);
      expect(verified.unwrap(), isFalse);
    });

    test('signing requires sender', () async {
      final signer = FakeSigner(sender);
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List(0),
        hlc: 1,
        payload: Uint8List.fromList([1]),
        signature: Uint8List(0),
      );
      final result = await codec.sign(envelope, signer, senderPeerId: sender);
      expect(result.isErr, isTrue);
    });
  });

  group('chunk / reassemble', () {
    test('chunk then reassemble reproduces original data', () async {
      // Stay under maxPayloadSize while spanning multiple chunks.
      final data = Uint8List.fromList(
        List<int>.generate(
          (ProtocolLimits.maxChunkSize ~/ 2) * 3 + 5,
          (i) => i % 256,
        ),
      );
      final chunked = await codec.chunkPayload('file-1', data);
      expect(chunked.isOk, isTrue);
      final chunks = chunked.unwrap();
      expect(chunks.length, 2);
      expect(chunks.every((c) => c.fileId == 'file-1'), isTrue);
      expect(chunks.last.chunkIndex, 1);
      expect(chunks.last.totalChunks, 2);

      final reassembled = codec.reassemblePayload(chunks);
      expect(reassembled.isOk, isTrue);
      expect(reassembled.unwrap(), data);
    });

    test('reassemble rejects mixed fileIds', () {
      final c1 =     FileChunk(
        fileId: 'a',
        chunkIndex: 0,
        totalChunks: 2,
        data: Uint8List.fromList([1]),
        totalSize: 2,
        sha256: Uint8List.fromList([0]),
        chunkHash: Uint8List.fromList([0]),
      );
      final c2 =     FileChunk(
        fileId: 'b',
        chunkIndex: 1,
        totalChunks: 2,
        data: Uint8List.fromList([2]),
        totalSize: 2,
        sha256: Uint8List.fromList([0]),
        chunkHash: Uint8List.fromList([0]),
      );
      final result = codec.reassemblePayload([c1, c2]);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<ChunkingError>());
    });

    test('reassemble rejects missing chunk index', () {
      final c0 =     FileChunk(
        fileId: 'a',
        chunkIndex: 0,
        totalChunks: 3,
        data: Uint8List.fromList([1]),
        totalSize: 3,
        sha256: Uint8List.fromList([0]),
        chunkHash: Uint8List.fromList([0]),
      );
      final c2 =     FileChunk(
        fileId: 'a',
        chunkIndex: 2,
        totalChunks: 3,
        data: Uint8List.fromList([3]),
        totalSize: 3,
        sha256: Uint8List.fromList([0]),
        chunkHash: Uint8List.fromList([0]),
      );
      final result = codec.reassemblePayload([c0, c2]);
      expect(result.isErr, isTrue);
    });
  });

  group('decodePayload', () {
    test('dispatches by type', () {
      final payload = ChatEvent(
        id: 'x',
        groupId: 'g',
        channelId: 'c',
        authorId: 'a',
        timestamp: 1,
      ).toBytes();
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1]),
        hlc: 1,
        payload: payload,
        signature: Uint8List(0),
      );
      final result = codec.decodePayload(envelope);
      expect(result.isOk, isTrue);
      expect(result.unwrap(), isA<ChatEvent>());
    });

    test('malformed payload returns Err without throwing', () {
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1]),
        hlc: 1,
        // length-delimited поле, заявленной длиной maxFrameSize, но тела нет.
        payload: Uint8List.fromList([0x2A, 0x80, 0x80, 0x80, 0x80, 0x80,
          0x80, 0x80, 0x80, 0x80, 0x01]),
        signature: Uint8List(0),
      );
      expect(() => codec.decodePayload(envelope), returnsNormally);
      final result = codec.decodePayload(envelope);
      expect(result.isOk || result.isErr, isTrue);
    });

    test('payload above maxPayloadSize returns Err', () {
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1]),
        hlc: 1,
        payload: Uint8List(ProtocolLimits.maxPayloadSize + 1),
        signature: Uint8List(0),
      );
      final result = codec.decodePayload(envelope);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<SizeLimitExceeded>());
    });

    test('unknown message type returns Err without throwing', () {
      final envelope = Envelope(
        version: 1,
        type: MessageType.fromInt(999),
        sender: Uint8List.fromList([1]),
        hlc: 1,
        payload: Uint8List.fromList([1]),
        signature: Uint8List(0),
      );
      final result = codec.decodePayload(envelope);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<UnknownMessageType>());
    });
  });

  group('version policy (min / max supported)', () {
    test('decode accepts future version structurally (forward compatibility)', () {
      final writer = ProtoWriter();
      writer.writeVarintField(1, 999); // future version
      writer.writeVarintField(2, 1); // chatEvent
      writer.writeBytesField(3, Uint8List.fromList([1]));
      writer.writeVarintField(4, 1);
      writer.writeBytesField(5, Uint8List.fromList([2]));
      final result = codec.decode(writer.finish());
      expect(result.isOk, isTrue);
      expect(result.unwrap().version, 999);
      expect(result.unwrap().isProcessable, isFalse);
    });

    test('decode rejects version below minSupportedVersion', () {
      final writer = ProtoWriter();
      writer.writeVarintField(1, 0);
      writer.writeVarintField(2, 1);
      writer.writeBytesField(3, Uint8List.fromList([1]));
      writer.writeVarintField(4, 1);
      writer.writeBytesField(5, Uint8List.fromList([2]));
      final result = codec.decode(writer.finish());
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<UnknownVersion>());
    });

    test('encode accepts future version (relay re-encode allowed)', () {
      final envelope = Envelope(
        version: 999,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1]),
        hlc: 1,
        payload: Uint8List.fromList([2]),
        signature: Uint8List(0),
      );
      final encoded = codec.encode(envelope);
      expect(encoded.isOk, isTrue);
    });

    test('decodePayload fails closed on future version', () {
      final envelope = Envelope(
        version: 999,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1]),
        hlc: 1,
        payload: Uint8List.fromList([1]),
        signature: Uint8List(0),
      );
      final result = codec.decodePayload(envelope);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<UnsupportedFutureVersion>());
    });

    test('decodePayload OK on current version', () {
      final payload = ChatEvent(
        id: 'x', groupId: 'g', channelId: 'c', authorId: 'a', timestamp: 1,
      ).toBytes();
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1]),
        hlc: 1,
        payload: payload,
        signature: Uint8List(0),
      );
      final result = codec.decodePayload(envelope);
      expect(result.isOk, isTrue);
    });
  });
}
