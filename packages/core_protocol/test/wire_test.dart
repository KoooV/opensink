import 'package:core_protocol/core_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('protobuf varint/fixed arithmetic', () {
    test('varint roundtrips values above 32 bits', () {
      const values = <int>[
        0,
        1,
        127,
        128,
        300,
        0xFFFFFFFF,
        0x100000000,
        1792852725602,
        9007199254740991,
      ];
      for (final value in values) {
        final writer = ProtoWriter();
        writer.writeVarintField(1, value);
        final reader = ProtoReader(writer.finish());
        expect(reader.readTag()?.$1, 1);
        expect(reader.readVarint(), value, reason: 'value=$value');
        expect(reader.isEmpty, isTrue);
      }
    });

    test('fixed64/fixed32 roundtrip without 32-bit truncation', () {
      const value = 1792852725602;
      final writer = ProtoWriter();
      writer.writeFixed64Field(1, value);
      writer.writeFixed32Field(2, 0xFEDCBA98);
      final reader = ProtoReader(writer.finish());
      expect(reader.readTag()?.$1, 1);
      expect(reader.readFixed64(), value);
      expect(reader.readTag()?.$1, 2);
      expect(reader.readFixed32(), 0xFEDCBA98);
      expect(reader.isEmpty, isTrue);
    });
  });
}
