import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_crypto/crypto_exceptions.dart';

/// AEAD-шифрование: XChaCha20-Poly1305.
///
/// Выбран вместо AES-GCM по причине устойчивости к повторному использованию
/// nonce (nonce misuse resistance) — критично в P2P, где нет центрального
/// координатора для учёта использованных nonce. 192-битный nonce позволяет
/// генерировать его случайно с forsvanshingly малой вероятностью коллизии.
///
/// Реализация берётся из [package:cryptography], собственные примитивы не
/// изобретаются.
class XChaCha20Poly1305Aead {
  XChaCha20Poly1305Aead();

  final _algorithm = const XChaCha20Poly1305();

  /// Шифрует [plaintext] с [aad] (associated data, не шифруется, но защищается).
  /// Возвращает зашифрованные данные в формате: nonce (24 байта) + ciphertext.
  Future<CryptoResult<Uint8List>> encrypt({
    required SecretKey key,
    required Uint8List plaintext,
    Uint8List? aad,
  }) async {
    try {
      final nonce = _algorithm.newNonce();
      final ciphertext = await _algorithm.encrypt(
        plaintext,
        secretKey: key,
        nonce: nonce,
        aead: aad != null ? AeadParameters(aad: aad) : null,
      );
      final result = Uint8List(nonce.length + ciphertext.length);
      result.setRange(0, nonce.length, nonce);
      result.setRange(nonce.length, result.length, ciphertext);
      return Ok(result);
    } on Exception {
      return const Err(EncryptionFailed());
    }
  }

  /// Расшифровывает [data] (формат: nonce 24 байта + ciphertext).
  Future<CryptoResult<Uint8List>> decrypt({
    required SecretKey key,
    required Uint8List data,
    Uint8List? aad,
  }) async {
    if (data.length < 24) {
      return const Err(DecryptionFailed());
    }
    final nonce = Uint8List(24);
    nonce.setRange(0, 24, data, 0);
    final ciphertext = Uint8List.fromList(data.sublist(24));
    try {
      final plaintext = await _algorithm.decrypt(
        ciphertext,
        secretKey: key,
        nonce: nonce,
        aead: aad != null ? AeadParameters(aad: aad) : null,
      );
      return Ok(plaintext);
    } on Exception {
      return const Err(DecryptionFailed());
    }
  }
}

/// Ошибка шифрования AEAD.
class EncryptionFailed extends CryptoError {
  const EncryptionFailed();
}

/// Сгенерировать случайный секретный ключ для AEAD (256 бит).
Future<SecretKey> generateAeadKey() async {
  final algorithm = const XChaCha20Poly1305();
  return await algorithm.newSecretKey();
}
