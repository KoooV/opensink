import 'dart:math';

import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'package:cryptography/dart.dart';

/// Провайдер криптографических алгоритмов на базе чистых Dart-реализаций
/// из [package:cryptography/dart.dart].
///
/// Использует классы DartEd25519, DartX25519, DartXchacha20 и т.д.
/// напрямую, минуя статический экземпляр библиотеки и фабрики алгоритмов,
/// которые внутри обращаются к статическому экземпляру библиотеки.
/// Это предотвращает инициализацию браузерных привязок Web Crypto API
/// на Node.js (dart2js), где Web Crypto API недоступен (дефект D-15).
///
/// Все алгоритмы создаются с явным [Random.secure()], чтобы
/// заполнение безопасными случайными байтами не проверяло
/// поддержку браузерных привязок (что происходит в браузерной
/// реализации при random == null).
class CryptoProvider {
  CryptoProvider._();

  static final CryptoProvider instance = CryptoProvider._();

  static final _random = Random();

  /// Ed25519-алгоритм для подписи и верификации.
  crypto_pkg.Ed25519 get ed25519 =>
      DartEd25519(sha512: const DartSha512(), random: _random);

  /// X25519-алгоритм для ключевого обмена.
  crypto_pkg.X25519 get x25519 => DartX25519(random: _random);

  /// XChaCha20-Poly1305 AEAD-алгоритм.
  crypto_pkg.Xchacha20 get xchacha20Poly1305Aead =>
      DartXchacha20.poly1305Aead(random: _random);

  /// HKDF key derivation.
  crypto_pkg.Hkdf hkdf({
    required crypto_pkg.Hmac hmac,
    required int outputLength,
  }) =>
      DartHkdf(hmac: hmac, outputLength: outputLength);

  /// HMAC-алгоритм для заданного хэша.
  crypto_pkg.Hmac hmac(crypto_pkg.HashAlgorithm hashAlgorithm) =>
      DartHmac(hashAlgorithm);

  /// SHA-256 хэш-алгоритм.
  crypto_pkg.Sha256 get sha256 => const DartSha256();

  /// SHA-512 хэш-алгоритм.
  crypto_pkg.Sha512 get sha512 => const DartSha512();

  /// PBKDF2 key derivation.
  crypto_pkg.Pbkdf2 pbkdf2({
    required crypto_pkg.MacAlgorithm macAlgorithm,
    required int iterations,
    required int bits,
  }) =>
      DartPbkdf2(
        macAlgorithm: macAlgorithm,
        iterations: iterations,
        bits: bits,
      );

  /// AES-GCM cipher с заданной длиной ключа.
  crypto_pkg.AesGcm aesGcm({
    int secretKeyLength = 32,
    int nonceLength = 12,
  }) =>
      DartAesGcm(
        secretKeyLength: secretKeyLength,
        nonceLength: nonceLength,
        random: _random,
      );
}
