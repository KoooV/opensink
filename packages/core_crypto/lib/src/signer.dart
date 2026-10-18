import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';
import 'identity.dart';

/// Stateless Ed25519 подписчик / верификатор.
///
/// Все подписные операции детерминированы и не содержат секретов в логах.
class CryptoSigner {
  const CryptoSigner();

  /// Подписывает байты закрытым ключом. Возвращает hex-подпись.
  Future<String> sign(Uint8List data, SecretKey privateKey) async {
    final algorithm = Ed25519();
    final signature = await algorithm.sign(data, privateKey: privateKey);
    return signature.hex;
  }

  /// Верифицирует hex-подпись по открытому ключу.
  Future<bool> verify(Uint8List data, String signatureHex, PublicKey publicKey) async {
    final algorithm = Ed25519();
    // TODO(verify): уточнить API десеализации подписи из hex в package:cryptography v3.
    // Возможно, требуется Ed25519Signature.fromHex или алгоритм-специфичный метод.
    final signature = Ed25519Signature.fromHex(signatureHex);
    return await algorithm.verify(data, signature: signature, publicKey: publicKey);
  }

  /// Подписывает групповое событие по его каноническому JSON-представлению.
  Future<String> signEvent(GroupEvent event, SecretKey privateKey) async {
    final canonical = const JsonEncoder().convert(event.toCanonicalMap());
    return sign(Uint8List.fromList(utf8.encode(canonical)), privateKey);
  }

  /// Верифицирует подпись группового события.
  Future<bool> verifyEvent(GroupEvent event, PublicKey publicKey) async {
    final canonical = const JsonEncoder().convert(event.toCanonicalMap());
    return await verify(
      Uint8List.fromList(utf8.encode(canonical)),
      event.signature,
      publicKey,
    );
  }
}
