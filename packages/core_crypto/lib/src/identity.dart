import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';
import 'bip39.dart';
import 'hkdf.dart';

/// Реализация [Identity] с парами ключей Ed25519 и X25519.
///
/// Секреты не попадают в логи: [toString] не раскрывает содержимое
/// [ed25519PrivateKey], [x25519PrivateKey] или [mnemonic].
class CryptoIdentity extends Identity {
  CryptoIdentity({
    required this.peerId,
    required this.userId,
    required this.ed25519PublicKey,
    required this.ed25519PrivateKey,
    required this.x25519PublicKey,
    required this.x25519PrivateKey,
    this.mnemonic,
    this.x25519BindingSignature,
  });

  @override
  final PeerId peerId;

  @override
  final UserId userId;

  final PublicKey ed25519PublicKey;
  final SecretKey ed25519PrivateKey;
  final PublicKey x25519PublicKey;
  final SecretKey x25519PrivateKey;
  final String? mnemonic;

  /// Подпись открытого ключа X25519 закрытым ключом Ed25519 (binding).
  /// Hex-подпись; null, если не вычислялась (generateIdentity без binding).
  final String? x25519BindingSignature;

  @override
  Map<String, Object?> toPublicMap() => {
        'peerId': bytesToHex((ed25519PublicKey as SimplePublicKey).bytes),
        'userId': userId.value,
        'x25519PublicKey': bytesToHex((x25519PublicKey as SimplePublicKey).bytes),
      };

  /// Проверяет binding: подпись [x25519BindingSignature] ключом Ed25519
  /// над байтами открытого ключа X25519. Возвращает false при отсутствии
  /// подписи или неверной подписи — не бросает исключений.
  Future<bool> verifyBinding() async {
    if (x25519BindingSignature == null) {
      return false;
    }
    try {
      final algo = Ed25519();
      final expectedPublicKey = SimplePublicKey(
        Uint8List.fromList((ed25519PublicKey as SimplePublicKey).bytes),
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        hexToBytes(x25519BindingSignature!),
        publicKey: expectedPublicKey,
      );
      return await algo.verify(
        Uint8List.fromList((x25519PublicKey as SimplePublicKey).bytes),
        signature: signature,
      );
    } catch (_) {
      return false;
    }
  }

  @override
  String toString() =>
      'CryptoIdentity(userId=${userId.value}, peerId=${bytesToHex((ed25519PublicKey as SimplePublicKey).bytes)})';
}

Future<CryptoIdentity> generateIdentity() async {
  final ed25519 = Ed25519();
  final x25519 = X25519();

  final edKeyPair = await ed25519.newKeyPair();
  final xKeyPair = await x25519.newKeyPair();

  final edPublicKey = await edKeyPair.extractPublicKey();
  final xPublicKey = await xKeyPair.extractPublicKey();

  final edPrivateKeyBytes = await edKeyPair.extractPrivateKeyBytes();
  final xPrivateKeyBytes = await xKeyPair.extractPrivateKeyBytes();

  // Binding: подписываем открытый ключ X25519 закрытым ключом Ed25519.
  final bindingSignature = await ed25519.sign(
    xPublicKey.bytes,
    keyPair: edKeyPair,
  );

  return CryptoIdentity(
    peerId: PeerId(Uint8List.fromList(edPublicKey.bytes)),
    userId: UserId(bytesToHex(edPublicKey.bytes)),
    ed25519PublicKey: edPublicKey,
    ed25519PrivateKey: SecretKey(edPrivateKeyBytes),
    x25519PublicKey: xPublicKey,
    x25519PrivateKey: SecretKey(xPrivateKeyBytes),
    x25519BindingSignature: bytesToHex(bindingSignature.bytes),
  );
}

Future<CryptoIdentity> recoverIdentityFromMnemonic({
  required String mnemonic,
  String passphrase = '',
}) async {
  if (!Bip39.isValidMnemonic(mnemonic)) {
    throw ArgumentError('Invalid BIP-39 mnemonic phrase');
  }

  final seed = await Bip39.mnemonicToSeed(mnemonic, passphrase: passphrase);

  // Derive independent key material for Ed25519 and X25519 from the BIP-39 seed.
  final hkdf = GroupHkdf();
  final seedKey = SecretKey(seed);
  final edMaterial = await hkdf.deriveBytes(
    secret: seedKey,
    salt: Uint8List(32),
    info: Uint8List.fromList(utf8.encode('opensink/identity/ed25519/v1')),
    length: 32,
  );
  final xMaterial = await hkdf.deriveBytes(
    secret: seedKey,
    salt: Uint8List(32),
    info: Uint8List.fromList(utf8.encode('opensink/identity/x25519/v1')),
    length: 32,
  );

  // Восстанавливаем пары ключей из тех же seed, что и приватные (исправляет D-03).
  // Публичные ключи производятся из приватных через newKeyPairFromSeed — они
  // гарантированно соответствуют приватным ключам.
  final edAlgo = Ed25519();
  final xAlgo = X25519();

  final edKeyPair = await edAlgo.newKeyPairFromSeed(edMaterial);
  final xKeyPair = await xAlgo.newKeyPairFromSeed(xMaterial);

  final edPublicKey = await edKeyPair.extractPublicKey();
  final xPublicKey = await xKeyPair.extractPublicKey();

  final edPrivateKeyBytes = await edKeyPair.extractPrivateKeyBytes();
  final xPrivateKeyBytes = await xKeyPair.extractPrivateKeyBytes();

  // Binding: подписываем открытый ключ X25519 закрытым ключом Ed25519.
  final bindingSignature = await edAlgo.sign(
    xPublicKey.bytes,
    keyPair: edKeyPair,
  );

  return CryptoIdentity(
    peerId: PeerId(Uint8List.fromList(edPublicKey.bytes)),
    userId: UserId(bytesToHex(edPublicKey.bytes)),
    ed25519PublicKey: edPublicKey,
    ed25519PrivateKey: SecretKey(edPrivateKeyBytes),
    x25519PublicKey: xPublicKey,
    x25519PrivateKey: SecretKey(xPrivateKeyBytes),
    x25519BindingSignature: bytesToHex(bindingSignature.bytes),
    mnemonic: mnemonic,
  );
}

String generateMnemonic({int strength = 128}) {
  return Bip39.generateMnemonic(strength: strength);
}

bool isValidMnemonic(String mnemonic) {
  return Bip39.isValidMnemonic(mnemonic);
}