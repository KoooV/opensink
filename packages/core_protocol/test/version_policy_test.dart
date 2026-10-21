import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_protocol/core_protocol.dart';

final _sender = Uint8List.fromList([1, 2, 3]);

void main() {
  group('version policy', () {
    test('v1 is processable, future versions are forward-only', () {
      final v1 = Envelope(
        version: 1,
        type: MessageType.chatEvent,
        sender: _sender,
        hlc: 1,
        payload: Uint8List(0),
        signature: Uint8List(0),
      );
      final v999 = Envelope(
        version: 999,
        type: MessageType.chatEvent,
        sender: _sender,
        hlc: 1,
        payload: Uint8List(0),
        signature: Uint8List(0),
      );
      expect(v1.isProcessable, isTrue);
      expect(v999.isProcessable, isFalse);
    });

    test('structural roundtrip preserves future version', () {
      final envelope = Envelope(
        version: 42,
        type: MessageType.fromInt(777),
        sender: _sender,
        hlc: 5,
        payload: Uint8List.fromList([1, 2, 3]),
        signature: Uint8List(0),
      );
      final decoded = Envelope.fromBytes(envelope.toBytes());
      expect(decoded.version, 42);
      expect(decoded.type.value, 777);
      expect(decoded.isProcessable, isFalse);
    });

    test('unknown field survives forward-only re-encode', () {
      final writer = ProtoWriter();
      writer.writeVarintField(1, 3); // future version
      writer.writeVarintField(2, 1);
      writer.writeBytesField(3, _sender);
      writer.writeVarintField(4, 1);
      writer.writeBytesField(5, Uint8List.fromList([7]));
      writer.writeBytesField(250, Uint8List.fromList([0xAA, 0xBB]));
      final decoded = Envelope.fromBytes(writer.finish());
      expect(decoded.isProcessable, isFalse);
      // unknownFields хранят сырые байты поля (тег + длина + значение).
      expect(
        decoded.unknownFields[250],
        Uint8List.fromList([0xD2, 0x0F, 0x02, 0xAA, 0xBB]),
      );
      final reDecoded = Envelope.fromBytes(decoded.toBytes());
      expect(
        reDecoded.unknownFields[250],
        decoded.unknownFields[250],
      );
    });
  });
}
