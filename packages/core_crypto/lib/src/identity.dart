import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';
import 'hkdf.dart';

/// Идентичность пользователя: Ed25519 (подпись) + X25519 (обмен ключами).
///
/// PeerId = байты открытого ключа Ed25519.
/// Закрытые ключи никогда не покидают SecureKeyStore и не логируются.
class CryptoIdentity extends Identity {
  const CryptoIdentity({
    required super.peerId,
    required super.userId,
    required this.ed25519PublicKey,
    required this.ed25519PrivateKey,
    required this.x25519PublicKey,
    required this.x25519PrivateKey,
    this.mnemonic,
  });

  /// Открытый ключ Ed25519 (используется как PeerId).
  final PublicKey ed25519PublicKey;

  /// Закрытый ключ Ed25519.
  final SecretKey ed25519PrivateKey;

  /// Открытый ключ X25519 (для ключевого обмена).
  final PublicKey x25519PublicKey;

  /// Закрытый ключ X25519.
  final SecretKey x25519PrivateKey;

  /// Опциональная BIP-39 резервная фраза (мнемоника) для восстановления.
  final String? mnemonic;

  @override
  Map<String, Object?> toPublicMap() => {
        'peerId': ed25519PublicKey.hex,
        'userId': userId.value,
        'x25519PublicKey': x25519PublicKey.hex,
      };

  @override
  String toString() =>
      'CryptoIdentity(userId=${userId.value}, peerId=${ed25519PublicKey.hex})';
}

/// Сгенерировать новую идентичность: Ed25519 + X25519 ключевые пары.
Future<CryptoIdentity> generateIdentity() async {
  final ed25519 = Ed25519();
  final x25519 = X25519();

  final edKeyPair = await ed25519.newKeyPair();
  final xKeyPair = await x25519.newKeyPair();

  return CryptoIdentity(
    peerId: PeerId(edKeyPair.publicKey.bytes),
    userId: UserId(edKeyPair.publicKey.hex),
    ed25519PublicKey: edKeyPair.publicKey,
    ed25519PrivateKey: edKeyPair.privateKey,
    x25519PublicKey: xKeyPair.publicKey,
    x25519PrivateKey: xKeyPair.privateKey,
  );
}

/// Восстановить идентичность из BIP-39 мнемоники.
///
/// Derivation: mnemonic → seed (PBKDF2-HMAC-SHA512, 2048 итераций, соль
/// "mnemonic" + optional passphrase) → Ed25519 + X25519 ключи.
Future<CryptoIdentity> recoverIdentityFromMnemonic({
  required String mnemonic,
  String passphrase = '',
}) async {
  // TODO(verify): bip39 API — mnemonicToEntropy, mnemonicToSeed, валидация мнемоники.
  final entropy = bip39.mnemonicToEntropy(mnemonic);
  final seed = await bip39.mnemonicToSeed(mnemonic, passphrase: passphrase);

  // Производим Ed25519 и X25519 ключи из seed через HKDF.
  final hkdf = Hkdf();
  final edSecret = await hkdf.deriveBytes(
    secret: SecretKey(seed),
    salt: Uint8List(32),
    info: Uint8List.fromList(utf8.encode('opensink/identity/ed25519')),
    length: 32,
  );
  final xSecret = await hkdf.deriveBytes(
    secret: SecretKey(seed),
    salt: Uint8List(32),
    info: Uint8List.fromList(utf8.encode('opensink/identity/x25519')),
    length: 32,
  );

  final edAlgorithm = Ed25519();
  final xAlgorithm = X25519();

  final edKeyPair = await edAlgorithm.newKeyPairFromSeed(
    SeedMaterial(edSecret),
  );
  final xKeyPair = await xAlgorithm.newKeyPairFromSeed(
    SeedMaterial(xSecret),
  );

  return CryptoIdentity(
    peerId: PeerId(edKeyPair.publicKey.bytes),
    userId: UserId(edKeyPair.publicKey.hex),
    ed25519PublicKey: edKeyPair.publicKey,
    ed25519PrivateKey: edKeyPair.privateKey,
    x25519PublicKey: xKeyPair.publicKey,
    x25519PrivateKey: xKeyPair.privateKey,
    mnemonic: mnemonic,
  );
}

/// Генерировать новую BIP-39 мнемонику (12 слов, 128 бит энтропии).
String generateMnemonic() {
  return bip39.generateMnemonic();
}

/// Проверить валидность BIP-39 мнемоники.
bool isValidMnemonic(String mnemonic) {
  return bip39.validateMnemonic(mnemonic);
}
