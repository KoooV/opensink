import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

Uint8List sha256Bytes(List<int> data) {
  final digest = crypto.sha256.convert(data);
  return Uint8List.fromList(digest.bytes);
}

String sha256Hex(List<int> data) => crypto.sha256.convert(data).toString();

Uint8List sha256First20(List<int> data) {
  final digest = sha256Bytes(data);
  return Uint8List.fromList(digest.sublist(0, 20));
}

String topicHashHex(String topic) => sha256Hex(utf8.encode(topic));

/// WebTorrent tracker использует binary strings: один char code = один байт.
String bytesToBinaryString(List<int> bytes) => String.fromCharCodes(bytes);

List<int> binaryStringToBytes(String value) =>
    value.codeUnits.map((code) => code & 0xFF).toList(growable: false);

String base64UrlNoPadding(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List? base64UrlNoPaddingDecode(String value) {
  try {
    final normalized = value.padRight((value.length + 3) ~/ 4 * 4, '=');
    return Uint8List.fromList(base64Url.decode(normalized));
  } catch (_) {
    return null;
  }
}
