import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';
import 'hkdf.dart';

/// Stateless Ed25519 подписчик / верификатор.
///
/// Реализует доменную [Signer]. Подписываются ровно те байты, которые идут
/// по сети (сериализованный protobuf, не canonical JSON).
///
/// Сравнение подписи — constant-time на уровне [Ed25519.verify] из
/// package:cryptography.
class CryptoSigner implements Signer {
  const CryptoSigner(this.privateKey);

  final SecretKey privateKey;

  @override
  Future<String> sign(Uint8List data) async {
    final algorithm = Ed25519();
    final signature = await algorithm.sign(data, privateKey: privateKey);
    return signature.hex;
  }

  @override
  Future<bool> verify(
    Uint8List data,
    String signatureHex,
    PeerId peerId,
  ) async {
    final algorithm = Ed25519();
    final publicKey = await algorithm.publicKeyFromBytes(peerId.publicKey);
    final signature = Ed25519Signature.fromHex(signatureHex);
    return await algorithm.verify(
      data,
      signature: signature,
      publicKey: publicKey,
    );
  }
}
