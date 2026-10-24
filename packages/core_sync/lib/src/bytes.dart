import 'dart:typed_data';

const String _hexChars = '0123456789abcdef';

String hexEncode(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(_hexChars[(b >> 4) & 0x0f]);
    out.write(_hexChars[b & 0x0f]);
  }
  return out.toString();
}

/// Декодирует hex. Возвращает null для невалидного входа.
Uint8List? hexDecode(String hex) {
  if (hex.isEmpty || hex.length.isOdd) return null;
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = _nibble(hex.codeUnitAt(i * 2));
    final lo = _nibble(hex.codeUnitAt(i * 2 + 1));
    if (hi < 0 || lo < 0) return null;
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int _nibble(int code) {
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
  return -1;
}
