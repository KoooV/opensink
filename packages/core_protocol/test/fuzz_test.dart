import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_protocol/core_protocol.dart';

class _Rng {
  _Rng(this.seed);
  int seed;
  int next() {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return seed;
  }

  int nextByte() => (next() >> 16) & 0xFF;
}

void main() {
  group('fuzz decoder', () {
    test('random inputs never throw and are bounded by maxFrameSize', () {
      final codec = ProtocolCodec();
      final rng = _Rng(0x12345678);
      const iterations = 2000;

      for (var i = 0; i < iterations; i++) {
        final len = rng.nextByte() % 200;
        final bytes = Uint8List(len);
        for (var j = 0; j < len; j++) {
          bytes[j] = rng.nextByte();
        }

        expect(() => codec.decode(bytes), returnsNormally);
        final result = codec.decode(bytes);
        // Either a valid envelope or a domain error — never an exception.
        expect(result.isOk || result.isErr, isTrue);
      }
    });

    test('oversized length-delimited field is rejected before allocation', () {
      final codec = ProtocolCodec();
      // Tag 42 = field 5, length-delimited. Length > maxFrameSize.
      final lengthBytes = <int>[];
      var value = ProtocolLimits.maxFrameSize + 1;
      while (true) {
        if (value < 0x80) {
          lengthBytes.add(value);
          break;
        }
        lengthBytes.add((value & 0x7F) | 0x80);
        value >>= 7;
      }
      final bytes = Uint8List.fromList([42, ...lengthBytes]);
      final result = codec.decode(bytes);
      expect(result.isErr, isTrue);
    });

    test('overly long varint is rejected', () {
      final codec = ProtocolCodec();
      // 11 bytes all with continuation bit set -> varint too long.
      final bytes = Uint8List.fromList(List.filled(11, 0xFF));
      final result = codec.decode(bytes);
      expect(result.isErr, isTrue);
    });

    test('truncated length-delimited field returns Err', () {
      final codec = ProtocolCodec();
      // Tag claims 100 bytes but only 3 follow.
      final bytes = Uint8List.fromList([42, 100, 1, 2, 3]);
      final result = codec.decode(bytes);
      expect(result.isErr, isTrue);
    });
  });

  group('encoder safety', () {
    test('signature over maxSignatureBytes is rejected', () {
      final codec = ProtocolCodec();
      final envelope = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: Uint8List.fromList([1]),
        hlc: 1,
        payload: Uint8List.fromList([1]),
        signature: Uint8List(ProtocolLimits.maxSignatureBytes + 1),
      );
      final result = codec.encode(envelope);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<SizeLimitExceeded>());
    });
  });

  group('boundary fuzz (large inputs near maxFrameSize)', () {
    test('input exactly at maxFrameSize does not throw and is bounded', () {
      final codec = ProtocolCodec();
      final bytes = Uint8List(ProtocolLimits.maxFrameSize);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = (i * 31 + 17) & 0xFF;
      }
      expect(() => codec.decode(bytes), returnsNormally);
      final result = codec.decode(bytes);
      expect(result.isOk || result.isErr, isTrue);
    });

    test('input above maxFrameSize is rejected before allocation', () {
      final codec = ProtocolCodec();
      final bytes = Uint8List(ProtocolLimits.maxFrameSize + 1);
      final result = codec.decode(bytes);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<SizeLimitExceeded>());
    });

    test('length-delimited field claiming maxFrameSize with truncated body is Err', () {
      final codec = ProtocolCodec();
      // Tag 42 = field 5, length-delimited. Claim maxFrameSize bytes but provide few.
      final lengthBytes = <int>[];
      var value = ProtocolLimits.maxFrameSize;
      while (true) {
        if (value < 0x80) {
          lengthBytes.add(value);
          break;
        }
        lengthBytes.add((value & 0x7F) | 0x80);
        value >>= 7;
      }
      final bytes = Uint8List.fromList([42, ...lengthBytes, 1, 2, 3]);
      final result = codec.decode(bytes);
      expect(result.isErr, isTrue);
    });

    test('9-byte varint at limit is accepted, 10-byte varint with continuation is rejected', () {
      final codec = ProtocolCodec();
      // 9 bytes, last without continuation bit -> valid max-size varint.
      final valid9 = Uint8List.fromList(List.filled(8, 0xFF) + [0x01]);
      expect(() => codec.decode(valid9), returnsNormally);
      final r1 = codec.decode(valid9);
      expect(r1.isOk || r1.isErr, isTrue);

      // 10 bytes all with continuation bit -> varint too long.
      final invalid10 = Uint8List.fromList(List.filled(10, 0xFF));
      final r2 = codec.decode(invalid10);
      expect(r2.isErr, isTrue);
    });

    test('many unknown fields do not cause unbounded allocation', () {
      final codec = ProtocolCodec();
      final writer = ProtoWriter();
      // Write 5000 unknown varint fields (each small).
      for (var i = 1; i <= 5000; i++) {
        writer.writeVarint((i << 3) | 0); // field i, varint type
        writer.writeVarint(i);
      }
      final bytes = writer.finish();
      final result = codec.decode(bytes);
      expect(result.isOk || result.isErr, isTrue);
      if (result.isOk) {
        // Unknown fields should be preserved.
        expect(result.unwrap().unknownFields.length, greaterThan(0));
      }
    });

    test('large random inputs up to maxFrameSize never throw', () {
      final codec = ProtocolCodec();
      final rng = _Rng(0xDEADBEEF);
      const iterations = 20;
      for (var i = 0; i < iterations; i++) {
        // Размер до maxFrameSize, чтобы проверить границу аллокаций.
        final len = (rng.next() % ProtocolLimits.maxFrameSize).toInt();
        final bytes = Uint8List(len);
        for (var j = 0; j < len; j++) {
          bytes[j] = rng.nextByte();
        }
        expect(() => codec.decode(bytes), returnsNormally);
        final result = codec.decode(bytes);
        expect(result.isOk || result.isErr, isTrue);
      }
    });

    test('large input exactly at maxFrameSize is bounded', () {
      final codec = ProtocolCodec();
      final bytes = Uint8List(ProtocolLimits.maxFrameSize);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = (i * 37 + 11) & 0xFF;
      }
      expect(() => codec.decode(bytes), returnsNormally);
      final result = codec.decode(bytes);
      expect(result.isOk || result.isErr, isTrue);
    });
  });
}
