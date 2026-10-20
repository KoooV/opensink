import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'package:core_domain/core_domain.dart';
import 'crypto_exceptions.dart';

/// AEAD-шифрование XChaCha20-Poly1305.
///
/// Wire format: nonce(24 байта) || ciphertext || mac(16 байт).
/// Nonce генерируется случайным образом; для тестовых векторов можно
/// передать фиксированный nonce (использовать только в тестах).
class XChaCha20Poly1305Aead {
  XChaCha20Poly1305Aead();

  final _algorithm = crypto_pkg.Xchacha20.poly1305Aead();

  static const int _nonceLength = 24;
  static const int _macLength = 16;

  Future<CryptoResult<Uint8List>> encrypt({
    required crypto_pkg.SecretKey key,
    required Uint8List plaintext,
    Uint8List? aad,
    /// Не использовать в продакшене — только для тестовых векторов.
    Uint8List? nonce,
  }) async {
    try {
      final secretBox = await _algorithm.encrypt(
        plaintext,
        secretKey: key,
        nonce: nonce,
        aad: aad ?? const <int>[],
      );
      final result = Uint8List(
        secretBox.nonce.length +
            secretBox.cipherText.length +
            secretBox.mac.bytes.length,
      );
      result.setRange(0, secretBox.nonce.length, secretBox.nonce);
      result.setRange(
        secretBox.nonce.length,
        secretBox.nonce.length + secretBox.cipherText.length,
        secretBox.cipherText,
      );
      result.setRange(
        secretBox.nonce.length + secretBox.cipherText.length,
        result.length,
        secretBox.mac.bytes,
      );
      return Ok(result);
    } on Exception {
      return const Err(EncryptionFailed());
    }
  }

  Future<CryptoResult<Uint8List>> decrypt({
    required crypto_pkg.SecretKey key,
    required Uint8List data,
    Uint8List? aad,
  }) async {
    if (data.length < _nonceLength + _macLength) {
      return const Err(DecryptionFailed());
    }

    final nonce = Uint8List.fromList(data.sublist(0, _nonceLength));
    final cipherText = Uint8List.fromList(
      data.sublist(_nonceLength, data.length - _macLength),
    );
    final macBytes = Uint8List.fromList(data.sublist(data.length - _macLength));

    final secretBox = crypto_pkg.SecretBox(
      cipherText,
      nonce: nonce,
      mac: crypto_pkg.Mac(macBytes),
    );

    try {
      final plaintext = await _algorithm.decrypt(
        secretBox,
        secretKey: key,
        aad: aad ?? const <int>[],
      );
      return Ok(Uint8List.fromList(plaintext));
    } on Exception {
      return const Err(DecryptionFailed());
    }
  }
}

Future<crypto_pkg.SecretKey> generateAeadKey() async {
  final algorithm = crypto_pkg.Xchacha20.poly1305Aead();
  return await algorithm.newSecretKey();
}
