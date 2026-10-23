import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_protocol/core_protocol.dart';

void main() {
  group('size limits', () {
    final sender = Uint8List.fromList([1, 2, 3]);
    final codec = ProtocolCodec();

    test('payload above maxPayloadSize is rejected on decode', () {
      // Собираем сырой конверт минуя encode, чтобы проверить именно decode-чек.
      final writer = ProtoWriter();
      writer.writeVarintField(1, 1);
      writer.writeVarintField(2, 1);
      writer.writeBytesField(3, sender);
      writer.writeVarintField(4, 1);
      writer.writeBytesField(5, Uint8List(ProtocolLimits.maxPayloadSize + 1));
      final raw = writer.finish();
      final result = codec.decode(raw);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<SizeLimitExceeded>());
    });

    test('frame above maxFrameSize is rejected on decode', () {
      final big = Uint8List(ProtocolLimits.maxFrameSize + 1);
      final result = codec.decode(big);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<SizeLimitExceeded>());
    });

    test('invalid UTF-8 in string field is rejected', () {
      final reader = ProtoReader(Uint8List.fromList([10, 3, 0xFF, 0xFE, 0x00]));
      expect(reader.readStringField, throwsA(isA<DecodeError>()));
    });

    test('varint longer than maxVarintBytes is rejected', () {
      final reader = ProtoReader(Uint8List.fromList(List.filled(11, 0xFF)));
      expect(reader.readVarint, throwsA(isA<DecodeError>()));
    });

    test('readBytes exceeding remaining buffer is rejected', () {
      final reader = ProtoReader(Uint8List.fromList([2, 0x05]));
      expect(reader.readBytes, throwsA(isA<DecodeError>()));
    });

    test('encode of oversized sender is rejected', () {
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List(ProtocolLimits.maxPeerIdBytes + 1),
        hlc: 1,
        payload: Uint8List.fromList([1]),
        signature: Uint8List(0),
      );
      final result = codec.encode(envelope);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<SizeLimitExceeded>());
    });
  });
}
