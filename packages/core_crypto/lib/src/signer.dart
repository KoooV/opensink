import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';
import 'hkdf.dart';

class CryptoSigner implements Signer {
  CryptoSigner(this.privateKey);

  final SecretKey privateKey;

  @override
  Future<String> sign(Uint8List data) async {
    final algorithm = Ed25519();
    final privateKeyBytes = await privateKey.extractBytes();

    // Восстанавливаем ключевую пару из того же seed, что и приватный ключ,
    // чтобы открытый ключ был производным от приватного (D-02).
    final keyPair = await algorithm.newKeyPairFromSeed(privateKeyBytes);

    final signature = await algorithm.sign(data, keyPair: keyPair);
    return bytesToHex(signature.bytes);
  }

  @override
  Future<bool> verify(
    Uint8List data,
    String signatureHex,
    PeerId peerId,
  ) async {
    // Любое некорректное входящее значение (не-hex, неверная длина,
    // пустая подпись, неверная длина ключа в PeerId) должно вернуть false,
    // а не бросить исключение.
    try {
      final algorithm = Ed25519();
      final signatureBytes = hexToBytes(signatureHex);

      final expectedPublicKey = SimplePublicKey(
        Uint8List.fromList(peerId.publicKey),
        type: KeyPairType.ed25519,
      );

      final signature = Signature(
        signatureBytes,
        publicKey: expectedPublicKey,
      );

      return await algorithm.verify(data, signature: signature);
    } catch (_) {
      return false;
    }
  }
}
