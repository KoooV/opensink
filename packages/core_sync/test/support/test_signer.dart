import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:crypto/crypto.dart';

import 'package:core_sync/src/bytes.dart';

/// Детерминированный тестовый подписчик.
///
/// HMAC-SHA256 с ключом, производным от id автора. Это НЕ production-
/// криптография: тест не должен зависеть от скорости Ed25519 на 1000 прогонах.
class TestSigner implements Signer {
  TestSigner(this.authorHex);

  final String authorHex;

  @override
  Future<String> sign(Uint8List data) async {
    final key = hexDecode(authorHex)!;
    final mac = Hmac(sha256, key).convert(data);
    return mac.toString();
  }

  @override
  Future<bool> verify(
    Uint8List data,
    String signatureHex,
    PeerId peerId,
  ) async {
    final key = peerId.publicKey;
    final mac = Hmac(sha256, key).convert(data);
    return mac.toString() == signatureHex;
  }
}

UserId testAuthor(int index) {
  final digest = sha256.convert(utf8.encode('test-author-$index'));
  return UserId(digest.toString());
}
