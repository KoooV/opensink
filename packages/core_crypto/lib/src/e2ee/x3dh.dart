import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import '../hkdf.dart';

class X3DH {
  X3DH();

  final _x25519 = X25519();
  final _ed25519 = Ed25519();
  final _hkdf = GroupHkdf();

  Future<X3DHKeyBundle> generateKeyBundle() async {
    final ikPair = await _x25519.newKeyPair();
    final spkPair = await _x25519.newKeyPair();
    final opkPair = await _x25519.newKeyPair();

    final ikPublicKey = await ikPair.extractPublicKey();
    final spkPublicKey = await spkPair.extractPublicKey();
    final opkPublicKey = await opkPair.extractPublicKey();

    final spkSignature = await _ed25519.sign(
      spkPublicKey.bytes,
      keyPair: ikPair,
    );

    final ikPrivateKeyBytes = await ikPair.extractPrivateKeyBytes();
    final spkPrivateKeyBytes = await spkPair.extractPrivateKeyBytes();
    final opkPrivateKeyBytes = await opkPair.extractPrivateKeyBytes();

    return X3DHKeyBundle(
      identityKey: ikPublicKey,
      identityPrivateKey: SecretKey(ikPrivateKeyBytes),
      signedPrekey: spkPublicKey,
      signedPrekeyPrivateKey: SecretKey(spkPrivateKeyBytes),
      signedPrekeySignature: bytesToHex(spkSignature.bytes),
      oneTimePrekey: opkPublicKey,
      oneTimePrekeyPrivateKey: SecretKey(opkPrivateKeyBytes),
    );
  }

  Future<X3DHSenderResult> sender({
    required X3DHPublicBundle remoteBundle,
    bool useOneTimePrekey = true,
  }) async {
    final ephemeral = await _x25519.newKeyPair();

    final dh2 = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: remoteBundle.identityKey,
    );
    final dh3 = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: remoteBundle.signedPrekey,
    );
    SecretKey? dh4;
    if (useOneTimePrekey && remoteBundle.oneTimePrekey != null) {
      dh4 = await _x25519.sharedSecretKey(
        keyPair: ephemeral,
        remotePublicKey: remoteBundle.oneTimePrekey!,
      );
    }

    final sharedKey = await _deriveSharedKey(
      dh2: dh2,
      dh3: dh3,
      dh4: dh4,
    );

    final ephemeralPublicKey = await ephemeral.extractPublicKey();

    return X3DHSenderResult(
      ephemeralPublicKey: ephemeralPublicKey,
      sharedKey: sharedKey,
      usedOneTimePrekey: dh4 != null,
    );
  }

  Future<SecretKey> receiver({
    required X3DHKeyBundle bundle,
    required PublicKey senderEphemeralPublicKey,
    required bool usedOneTimePrekey,
  }) async {
    // cryptography v2.9.0 lacks KeyPair.fromPrivateKeyBytes, but
    // SimpleKeyPairData implements KeyPair and accepts raw private key bytes
    // plus the matching public key.  This is the same pattern used by
    // CryptoSigner (signer.dart) for Ed25519.
    final identityKeyPair = SimpleKeyPairData(
      await bundle.identityPrivateKey.extractBytes(),
      publicKey: bundle.identityKey as SimplePublicKey,
      type: KeyPairType.x25519,
    );
    final spkKeyPair = SimpleKeyPairData(
      await bundle.signedPrekeyPrivateKey.extractBytes(),
      publicKey: bundle.signedPrekey as SimplePublicKey,
      type: KeyPairType.x25519,
    );

    final dh2 = await _x25519.sharedSecretKey(
      keyPair: identityKeyPair,
      remotePublicKey: senderEphemeralPublicKey,
    );
    final dh3 = await _x25519.sharedSecretKey(
      keyPair: spkKeyPair,
      remotePublicKey: senderEphemeralPublicKey,
    );

    SecretKey? dh4;
    if (usedOneTimePrekey &&
        bundle.oneTimePrekeyPrivateKey != null &&
        bundle.oneTimePrekey != null) {
      final opkKeyPair = SimpleKeyPairData(
        await bundle.oneTimePrekeyPrivateKey!.extractBytes(),
        publicKey: bundle.oneTimePrekey! as SimplePublicKey,
        type: KeyPairType.x25519,
      );
      dh4 = await _x25519.sharedSecretKey(
        keyPair: opkKeyPair,
        remotePublicKey: senderEphemeralPublicKey,
      );
    }

    return await _deriveSharedKey(dh2: dh2, dh3: dh3, dh4: dh4);
  }

  Future<SecretKey> _deriveSharedKey({
    required SecretKey dh2,
    required SecretKey dh3,
    SecretKey? dh4,
  }) async {
    final dh2Bytes = Uint8List.fromList(await dh2.extractBytes());
    final dh3Bytes = Uint8List.fromList(await dh3.extractBytes());
    final allDh = Uint8List.fromList([...dh2Bytes, ...dh3Bytes]);
    if (dh4 != null) {
      final dh4Bytes = Uint8List.fromList(await dh4.extractBytes());
      final combined = Uint8List.fromList([...allDh, ...dh4Bytes]);
      return await _hkdf.derive(
        secret: SecretKey(combined),
        salt: Uint8List(32),
        info: Uint8List.fromList(utf8.encode('opensink/x3dh/shared-key')),
        outputLength: 32,
      );
    }
    return await _hkdf.derive(
      secret: SecretKey(allDh),
      salt: Uint8List(32),
      info: Uint8List.fromList(utf8.encode('opensink/x3dh/shared-key')),
      outputLength: 32,
    );
  }
}

class X3DHPublicBundle {
  const X3DHPublicBundle({
    required this.identityKey,
    required this.signedPrekey,
    this.signedPrekeySignature,
    this.oneTimePrekey,
  });

  final PublicKey identityKey;
  final PublicKey signedPrekey;
  final String? signedPrekeySignature;
  final PublicKey? oneTimePrekey;
}

class X3DHKeyBundle {
  const X3DHKeyBundle({
    required this.identityKey,
    required this.identityPrivateKey,
    required this.signedPrekey,
    required this.signedPrekeyPrivateKey,
    required this.signedPrekeySignature,
    this.oneTimePrekey,
    this.oneTimePrekeyPrivateKey,
  });

  final PublicKey identityKey;
  final SecretKey identityPrivateKey;
  final PublicKey signedPrekey;
  final SecretKey signedPrekeyPrivateKey;
  final String signedPrekeySignature;
  final PublicKey? oneTimePrekey;
  final SecretKey? oneTimePrekeyPrivateKey;

  X3DHPublicBundle toPublicBundle() => X3DHPublicBundle(
        identityKey: identityKey,
        signedPrekey: signedPrekey,
        signedPrekeySignature: signedPrekeySignature,
        oneTimePrekey: oneTimePrekey,
      );
}

class X3DHSenderResult {
  const X3DHSenderResult({
    required this.ephemeralPublicKey,
    required this.sharedKey,
    required this.usedOneTimePrekey,
  });

  final PublicKey ephemeralPublicKey;
  final SecretKey sharedKey;
  final bool usedOneTimePrekey;
}

class X3DHSessionKeys {
  const X3DHSessionKeys({
    required this.rootKey,
    required this.sendingChainKey,
    required this.receivingChainKey,
  });

  final SecretKey rootKey;
  final SecretKey sendingChainKey;
  final SecretKey receivingChainKey;
}

Future<X3DHSessionKeys> x3dhToSessionKeys(SecretKey sharedSecret) async {
  final hkdf = GroupHkdf();
  final rootKey = await hkdf.deriveBytes(
    secret: sharedSecret,
    salt: Uint8List(32),
    info: Uint8List.fromList(utf8.encode('opensink/x3dh/session/root-key')),
    length: 32,
  );
  final sendingChainKey = await hkdf.deriveBytes(
    secret: sharedSecret,
    salt: Uint8List(32),
    info: Uint8List.fromList(utf8.encode('opensink/x3dh/session/sending-chain')),
    length: 32,
  );
  final receivingChainKey = await hkdf.deriveBytes(
    secret: sharedSecret,
    salt: Uint8List(32),
    info: Uint8List.fromList(
      utf8.encode('opensink/x3dh/session/receiving-chain'),
    ),
    length: 32,
  );
  return X3DHSessionKeys(
    rootKey: SecretKey(rootKey),
    sendingChainKey: SecretKey(sendingChainKey),
    receivingChainKey: SecretKey(receivingChainKey),
  );
}
