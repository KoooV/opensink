import 'dart:typed_data';

import 'package:core_protocol/core_protocol.dart' show RelayFrame;

/// Тег relay-кадра и версия wire-формата.
///
/// v2 обязателен: кадры без Ed25519-подписи и старый v1 не принимаются.
class RelayEnvelope {
  const RelayEnvelope._();

  static const List<int> magic = <int>[0x4F, 0x53, 0x52, 0x4C, 0x03]; // OSRL v3
  static const int prefixLength = 5;

  static Uint8List encode(RelayFrame frame) => encodeBytes(frame.toBytes());

  static Uint8List encodeBytes(List<int> frameBytes) {
    final out = Uint8List(prefixLength + frameBytes.length);
    out.setRange(0, prefixLength, magic);
    out.setRange(prefixLength, out.length, frameBytes);
    return out;
  }

  static bool isEnvelope(List<int> bytes) {
    if (bytes.length < prefixLength) {
      return false;
    }
    for (var i = 0; i < prefixLength; i++) {
      if (bytes[i] != magic[i]) {
        return false;
      }
    }
    return true;
  }

  /// Возвращает `null` для обычного payload и повреждённого кадра.
  static RelayFrame? decode(Uint8List bytes) {
    if (!isEnvelope(bytes)) {
      return null;
    }
    try {
      return RelayFrame.fromBytes(
        Uint8List.fromList(bytes.sublist(prefixLength)),
      );
    } catch (_) {
      return null;
    }
  }
}
