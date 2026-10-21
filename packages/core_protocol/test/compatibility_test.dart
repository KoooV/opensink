import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_protocol/core_protocol.dart';

final _sender = Uint8List.fromList([1, 2, 3]);

void main() {
  group('forward compatibility', () {
    test('old decoder reads new envelope with unknown field', () {
      final writer = ProtoWriter();
      writer.writeVarintField(1, 1); // version
      writer.writeVarintField(2, 5); // type (future)
      writer.writeBytesField(3, _sender);
      writer.writeVarintField(4, 5000); // hlc
      writer.writeBytesField(5, Uint8List.fromList([1, 2, 3])); // payload
      // Unknown field 50 = length-delimited: tag (50 << 3) | 2 = 402.
      writer.writeBytesField(50, Uint8List.fromList([9, 9, 9, 9]));
      final raw = writer.finish();

      final decoded = Envelope.fromBytes(raw);
      expect(decoded.version, 1);
      expect(decoded.type.value, 5);
      expect(decoded.sender, _sender);
      expect(decoded.hlc, 5000);
      expect(decoded.payload, Uint8List.fromList([1, 2, 3]));
      expect(decoded.unknownFields.containsKey(50), isTrue);
    });

    test('unknown field survives re-encode (forwarded unchanged)', () {
      final writer = ProtoWriter();
      writer.writeVarintField(1, 1);
      writer.writeVarintField(2, 1);
      writer.writeBytesField(3, _sender);
      writer.writeVarintField(4, 1);
      writer.writeBytesField(5, Uint8List.fromList([7]));
      // Unknown field 250 = varint 333: tag (250 << 3) | 0 = 2000.
      writer.writeVarint(2000);
      writer.writeVarint(333);
      final raw = writer.finish();

      final decoded = Envelope.fromBytes(raw);
      final reDecoded = Envelope.fromBytes(decoded.toBytes());
      expect(reDecoded.unknownFields[250], decoded.unknownFields[250]);
    });

    test('unknown message type decodes structurally', () {
      final writer = ProtoWriter();
      writer.writeVarintField(1, 2); // version 2 (future)
      writer.writeVarintField(2, 12345); // unknown type number
      writer.writeBytesField(3, _sender);
      writer.writeVarintField(4, 1);
      writer.writeBytesField(5, Uint8List.fromList([0]));
      final raw = writer.finish();

      final decoded = Envelope.fromBytes(raw);
      expect(decoded.version, 2);
      expect(decoded.type.value, 12345);
    });

    test('old v1 decoder reads new v2 envelope and forwards unknown field', () {
      // Новый узел собирает v2-конверт с полем, которого v1 не знает (поле 200).
      final writer = ProtoWriter();
      writer.writeVarintField(1, 2); // version 2 (новый)
      writer.writeVarintField(2, 1); // type chatEvent
      writer.writeBytesField(3, _sender);
      writer.writeVarintField(4, 9000);
      writer.writeBytesField(5, Uint8List.fromList([1, 2, 3]));
      // Неизвестное поле 200, length-delimited: тег (200 << 3) | 2 = 1602.
      writer.writeBytesField(200, Uint8List.fromList([0xAA, 0xBB]));
      final raw = writer.finish();

      // Старый узел десериализует тем же кодом (игнорирует неизвестные поля,
      // но сохраняет их для дальнейшей пересылки).
      final decoded = Envelope.fromBytes(raw);
      expect(decoded.version, 2);
      expect(decoded.type, MessageType.chatEvent);
      expect(decoded.sender, _sender);
      expect(decoded.hlc, 9000);
      expect(decoded.payload, Uint8List.fromList([1, 2, 3]));
      expect(decoded.unknownFields.containsKey(200), isTrue);

      // Пересылка: неизвестное поле сохраняется при повторном кодировании.
      final reDecoded = Envelope.fromBytes(decoded.toBytes());
      expect(reDecoded.unknownFields[200], decoded.unknownFields[200]);
    });
  });

  group('backward compatibility', () {
    test('minimal v1 envelope decodes', () {
      final writer = ProtoWriter();
      writer.writeVarintField(1, 1);
      writer.writeVarintField(2, 1);
      writer.writeBytesField(3, _sender);
      writer.writeVarintField(4, 1);
      writer.writeBytesField(5, Uint8List.fromList([0]));
      final raw = writer.finish();

      final result = ProtocolCodec().decode(raw);
      expect(result.isOk, isTrue);
      expect(result.unwrap().version, 1);
    });
  });
}
