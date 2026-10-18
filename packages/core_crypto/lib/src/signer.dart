import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';

/// Stateless Ed25519 подписчик / верификатор.
///
/// Реализует доменную [Signer]. Закрытый ключ хранится внутри экземпляра и не
/// попадает в логи.
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
    // TODO(verify): уточнить API десеализации подписи из hex в package:cryptography v3.
    final algorithm = Ed25519();
    final publicKey = await algorithm.publicKeyFromBytes(peerId.publicKey);
    final signature = Ed25519Signature.fromHex(signatureHex);
    return await algorithm.verify(data, signature: signature, publicKey: publicKey);
  }

  /// Подписывает груповое событие по его каноническому JSON-представлению.
  Future<String> signEvent(GroupEvent event) async {
    final canonical = const JsonEncoder().convert(event.toCanonicalMap());
    return sign(Uint8List.fromList(utf8.encode(canonical)));
  }

  /// Верифицирует подпись групового события.
  Future<bool> verifyEvent(GroupEvent event) async {
    final canonical = const JsonEncoder().convert(event.toCanonicalMap());
    return await verify(
      Uint8List.fromList(utf8.encode(canonical)),
      event.signature,
      PeerId(Uint8List.fromList(event.authorId.value.codeUnits)), // TODO(verify): authorId -> PeerId mapping
    );
  }
}
