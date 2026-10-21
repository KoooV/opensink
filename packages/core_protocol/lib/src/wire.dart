import 'dart:convert';
import 'dart:typed_data';

import 'limits.dart';
import 'protocol_error.dart';

/// Типы wire-полей protobuf.
enum WireType {
  varint(0),
  fixed64(1),
  lengthDelimited(2),
  startGroup(3),
  endGroup(4),
  fixed32(5);

  const WireType(this.value);
  final int value;
}

/// Читатель protobuf wire-формата с жёстким контролем границ и аллокаций.
///
/// Каждый метод проверяет границы буфера и ограничивает размер аллокаций,
/// чтобы некорректный или злонамеренный вход не мог вызвать OOM.
class ProtoReader {
  ProtoReader(Uint8List data) : _data = data;

  final Uint8List _data;
  int _pos = 0;

  int get length => _data.length;
  int get position => _pos;
  int get remaining => _data.length - _pos;
  bool get isEmpty => _pos >= _data.length;

  /// Читает один байт.
  int readByte() {
    if (_pos >= _data.length) {
      throw const DecodeError('unexpected end of stream');
    }
    return _data[_pos++];
  }

  /// Читает varint. Ограничивает длину [ProtocolLimits.maxVarintBytes].
  int readVarint() {
    int result = 0;
    int shift = 0;
    for (var i = 0; i < ProtocolLimits.maxVarintBytes; i++) {
      final b = readByte();
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) {
        return result;
      }
      shift += 7;
    }
    throw const DecodeError('varint too long');
  }

  /// Читает length-delimited поле (bytes/string/embedded message).
  /// Проверяет лимит размера *до* аллокации.
  Uint8List readBytes() {
    final length = readVarint();
    if (length > ProtocolLimits.maxFrameSize) {
      throw SizeLimitExceeded(length, ProtocolLimits.maxFrameSize);
    }
    if (_pos + length > _data.length) {
      throw const DecodeError('length-delimited field exceeds buffer');
    }
    final bytes = Uint8List.fromList(_data.sublist(_pos, _pos + length));
    _pos += length;
    return bytes;
  }

  /// Читает 64-битное little-endian значение.
  int readFixed64() {
    if (_pos + 8 > _data.length) {
      throw const DecodeError('unexpected end of stream');
    }
    final b = _data;
    final pos = _pos;
    _pos += 8;
    return b[pos] |
        (b[pos + 1] << 8) |
        (b[pos + 2] << 16) |
        (b[pos + 3] << 24) |
        (b[pos + 4] << 32) |
        (b[pos + 5] << 40) |
        (b[pos + 6] << 48) |
        (b[pos + 7] << 56);
  }

  /// Читает 32-битное little-endian значение.
  int readFixed32() {
    if (_pos + 4 > _data.length) {
      throw const DecodeError('unexpected end of stream');
    }
    final b = _data;
    final pos = _pos;
    _pos += 4;
    return b[pos] | (b[pos + 1] << 8) | (b[pos + 2] << 16) | (b[pos + 3] << 24);
  }

  /// Читает тег поля: возвращает (fieldNumber, wireType).
  /// Возвращает null, если поток закончился.
  (int fieldNumber, WireType wireType)? readTag() {
    if (isEmpty) {
      return null;
    }
    final tag = readVarint();
    final fieldNumber = tag >> 3;
    final wireTypeValue = tag & 0x7;
    WireType? wireType;
    for (final wt in WireType.values) {
      if (wt.value == wireTypeValue) {
        wireType = wt;
        break;
      }
    }
    if (wireType == null) {
      throw const DecodeError('unknown wire type');
    }
    return (fieldNumber, wireType);
  }

  /// Пропускает значение поля заданного wire-типа.
  void consumeField(WireType wireType) {
    switch (wireType) {
      case WireType.varint:
        readVarint();
        break;
      case WireType.fixed64:
        readFixed64();
        break;
      case WireType.lengthDelimited:
        readBytes();
        break;
      case WireType.fixed32:
        readFixed32();
        break;
      case WireType.startGroup:
      case WireType.endGroup:
        throw const DecodeError('groups are not supported');
    }
  }

  /// Помечает текущую позицию (используется для сбора сырых байтов поля).
  int mark() => _pos;

  /// Возвращает копию байтов из [start] (включительно) до [end] (исключительно).
  Uint8List slice(int start, int end) {
    if (start < 0 || end > _data.length || start > end) {
      throw const DecodeError('invalid slice bounds');
    }
    return Uint8List.fromList(_data.sublist(start, end));
  }

  /// Читает строку (length-delimited UTF-8) с проверкой лимита.
  String readStringField() {
    final bytes = readBytes();
    if (bytes.length > ProtocolLimits.maxStringBytes) {
      throw SizeLimitExceeded(bytes.length, ProtocolLimits.maxStringBytes);
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      throw const DecodeError('invalid UTF-8 in string field');
    }
  }
}

/// Писатель protobuf wire-формата.
class ProtoWriter {
  final List<int> _buffer = [];

  void writeByte(int b) {
    _buffer.add(b & 0xFF);
  }

  /// Кодирует значение как varint (little-endian base-128).
  void writeVarint(int value) {
    if (value < 0) {
      throw ArgumentError('negative value cannot be encoded as varint');
    }
    while (true) {
      if (value < 0x80) {
        _buffer.add(value);
        return;
      }
      _buffer.add((value & 0x7F) | 0x80);
      value >>= 7;
    }
  }

  /// Записывает тег поля: (field_number << 3) | wire_type.
  void writeTag(int fieldNumber, WireType wireType) {
    writeVarint((fieldNumber << 3) | wireType.value);
  }

  /// Записывает varint-поле.
  void writeVarintField(int fieldNumber, int value) {
    writeTag(fieldNumber, WireType.varint);
    writeVarint(value);
  }

  /// Записывает fixed64-поле.
  void writeFixed64Field(int fieldNumber, int value) {
    writeTag(fieldNumber, WireType.fixed64);
    for (var i = 0; i < 8; i++) {
      _buffer.add((value >> (i * 8)) & 0xFF);
    }
  }

  /// Записывает fixed32-поле.
  void writeFixed32Field(int fieldNumber, int value) {
    writeTag(fieldNumber, WireType.fixed32);
    for (var i = 0; i < 4; i++) {
      _buffer.add((value >> (i * 8)) & 0xFF);
    }
  }

  /// Записывает length-delimited байт-поле.
  void writeBytesField(int fieldNumber, Uint8List value) {
    writeTag(fieldNumber, WireType.lengthDelimited);
    writeVarint(value.length);
    _buffer.addAll(value);
  }

  /// Записывает строковое поле (UTF-8).
  void writeStringField(int fieldNumber, String value) {
    final bytes = utf8.encode(value);
    writeBytesField(fieldNumber, bytes);
  }

  /// Записывает сырые байты поля (включая тег) — для неполевых/неизвестных полей.
  void writeRawField(int fieldNumber, Uint8List rawBytes) {
    // rawBytes already contains tag + value; we trust ordering handled by caller.
    _buffer.addAll(rawBytes);
  }

  /// Записывает все незнакомые поля, отсортированные по номеру поля (детерминизм).
  void writeUnknownFields(Map<int, Uint8List> fields) {
    final sorted = fields.keys.toList()..sort();
    for (final fieldNumber in sorted) {
      writeRawField(fieldNumber, fields[fieldNumber]!);
    }
  }

  /// Завершает кодирование и возвращает байты.
  Uint8List finish() => Uint8List.fromList(_buffer);
}
