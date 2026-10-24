import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

/// Детерминированная Ed25519-идентичность для симулятора.
///
/// Ключи выводятся из фиксированного seed и кэшируются между прогонами:
/// 1000 прогонов используют одни и те же 3 автора, поэтому деривация
/// выполняется один раз, а подпись/верификация — реальным Ed25519.
class Ed25519Identity {
  Ed25519Identity._(this.author, this.signer);

  final UserId author;
  final Ed25519TestSigner signer;

  static final Map<int, Ed25519Identity> _cache = {};

  static Future<Ed25519Identity> create(int index) async {
    final cached = _cache[index];
    if (cached != null) return cached;
    final seed = sha256
        .convert(utf8.encode('sync-ed25519-author-$index'))
        .bytes;
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    final identity = Ed25519Identity._(
      UserId(hexEncode(publicKey.bytes)),
      Ed25519TestSigner(algorithm, keyPair),
    );
    _cache[index] = identity;
    return identity;
  }
}

class Ed25519TestSigner implements Signer {
  Ed25519TestSigner(this._algorithm, this._keyPair);

  final Ed25519 _algorithm;
  final SimpleKeyPair _keyPair;

  @override
  Future<String> sign(Uint8List data) async {
    final signature = await _algorithm.sign(data, keyPair: _keyPair);
    return hexEncode(signature.bytes);
  }

  @override
  Future<bool> verify(
    Uint8List data,
    String signatureHex,
    PeerId peerId,
  ) async {
    try {
      final signatureBytes = hexDecode(signatureHex);
      if (signatureBytes == null) return false;
      final signature = Signature(
        signatureBytes,
        publicKey: SimplePublicKey(peerId.publicKey, type: KeyPairType.ed25519),
      );
      return await _algorithm.verify(data, signature: signature);
    } catch (_) {
      return false;
    }
  }
}
