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

    final tempKeyPair = await algorithm.newKeyPair();
    final tempPublicKey = await tempKeyPair.extractPublicKey();

    final keyPair = SimpleKeyPairData(
      privateKeyBytes,
      publicKey: tempPublicKey,
      type: KeyPairType.ed25519,
    );

    final signature = await algorithm.sign(data, keyPair: keyPair);
    return bytesToHex(signature.bytes);
  }

  @override
  Future<bool> verify(
    Uint8List data,
    String signatureHex,
    PeerId peerId,
  ) async {
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
  }
}
