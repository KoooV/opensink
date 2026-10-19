import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';
import 'bip39.dart';
import 'hkdf.dart';

class CryptoIdentity extends Identity {
  CryptoIdentity({
    required this.peerId,
    required this.userId,
    required this.ed25519PublicKey,
    required this.ed25519PrivateKey,
    required this.x25519PublicKey,
    required this.x25519PrivateKey,
    this.mnemonic,
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

  @override
  Map<String, Object?> toPublicMap() => {
        'peerId': bytesToHex((ed25519PublicKey as SimplePublicKey).bytes),
        'userId': userId.value,
        'x25519PublicKey': bytesToHex((x25519PublicKey as SimplePublicKey).bytes),
      };

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

  return CryptoIdentity(
    peerId: PeerId(Uint8List.fromList(edPublicKey.bytes)),
    userId: UserId(bytesToHex(edPublicKey.bytes)),
    ed25519PublicKey: edPublicKey,
    ed25519PrivateKey: SecretKey(edPrivateKeyBytes),
    x25519PublicKey: xPublicKey,
    x25519PrivateKey: SecretKey(xPrivateKeyBytes),
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
    info: Uint8List.fromList(utf8.encode('opensink/bip39/ed25519')),
    length: 32,
  );
  final xMaterial = await hkdf.deriveBytes(
    secret: seedKey,
    salt: Uint8List(32),
    info: Uint8List.fromList(utf8.encode('opensink/bip39/x25519')),
    length: 32,
  );

  // TODO(verify): cryptography v2.x does not expose Ed25519/X25519 public-key
  // derivation from private key bytes. The public keys below are derived from
  // the same HKDF output as the private keys and will NOT match them.
  // Identities created via recoverIdentityFromMnemonic cannot be used for
  // signature verification or DH shared-secret computation with other peers
  // until cryptography v3.x or native FFI key derivation is available.
  return CryptoIdentity(
    peerId: PeerId(Uint8List.fromList(edMaterial)),
    userId: UserId(bytesToHex(edMaterial)),
    ed25519PublicKey: SimplePublicKey(
      edMaterial,
      type: KeyPairType.ed25519,
    ),
    ed25519PrivateKey: SecretKey(edMaterial),
    x25519PublicKey: SimplePublicKey(
      xMaterial,
      type: KeyPairType.x25519,
    ),
    x25519PrivateKey: SecretKey(xMaterial),
    mnemonic: mnemonic,
  );
}

String generateMnemonic({int strength = 128}) {
  return Bip39.generateMnemonic(strength: strength);
}

bool isValidMnemonic(String mnemonic) {
  return Bip39.isValidMnemonic(mnemonic);
}
