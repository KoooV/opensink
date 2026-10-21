import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';
import '../hkdf.dart';
import '../crypto_exceptions.dart';

/// X3DH key agreement (ослабленный вариант без OPK, см. DESIGN.md §13.1).
///
/// Используются только IK (identity key) и SPK (signed prekey). OPK исключён
/// из-за отсутствия координатора для гарантии одноразовости в P2P-сети.
class X3DH {
  X3DH();

  final _x25519 = X25519();
  final _ed25519 = Ed25519();
  final _hkdf = GroupHkdf();

  /// Контекст подписи привязки SPK к IK (DESIGN.md §13.2).
  static const _spkBindingContext = 'opensink/x3dh/spk-binding/v1';

  Future<X3DHKeyBundle> generateKeyBundle() async {
    final ikPair = await _x25519.newKeyPair();
    final spkPair = await _x25519.newKeyPair();
    // Ed25519 ключ для подписи привязки SPK (DESIGN.md §13.2).
    final signingPair = await _ed25519.newKeyPair();

    final ikPublicKey = await ikPair.extractPublicKey();
    final spkPublicKey = await spkPair.extractPublicKey();

    // SPK public key подписывается Ed25519 private key (binding, DESIGN.md §13.2).
    final signingContext = Uint8List.fromList(
      utf8.encode('$_spkBindingContext|'),
    );
    final spkBytes = Uint8List.fromList(spkPublicKey.bytes);
    final signingInput = Uint8List.fromList([...signingContext, ...spkBytes]);
    final spkSignature = await _ed25519.sign(
      signingInput,
      keyPair: signingPair,
    );

    final signingPairPublicKey = await signingPair.extractPublicKey();

    final ikPrivateKeyBytes = await ikPair.extractPrivateKeyBytes();
    final spkPrivateKeyBytes = await spkPair.extractPrivateKeyBytes();

    return X3DHKeyBundle(
      identityKey: ikPublicKey,
      identityPrivateKey: SecretKey(ikPrivateKeyBytes),
      signedPrekey: spkPublicKey,
      signedPrekeyPrivateKey: SecretKey(spkPrivateKeyBytes),
      ed25519PublicKey: signingPairPublicKey,
      signedPrekeySignature: bytesToHex(spkSignature.bytes),
    );
  }

  /// Вычисляет общий секрет с удалённой стороной.
  ///
  /// Перед любыми DH-вычислениями проверяется привязка SPK к IK
  /// (DESIGN.md §13.2). Неверная подпись → [Err] с [InvalidSignature],
  /// исключение не выбрасывается.
  Future<CryptoResult<X3DHSenderResult>> sender({
    required X3DHPublicBundle remoteBundle,
  }) async {
    // 1. Проверка привязки SPK → IK (DESIGN.md §13.2).
    final bindingValid = await _verifySpkBinding(remoteBundle);
    if (!bindingValid) {
      return const Err(InvalidSignature());
    }

    final ephemeral = await _x25519.newKeyPair();

    final dh2 = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: remoteBundle.identityKey,
    );
    final dh3 = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: remoteBundle.signedPrekey,
    );

    final sharedKey = await _deriveSharedKey(dh2: dh2, dh3: dh3);

    final ephemeralPublicKey = await ephemeral.extractPublicKey();

    return Ok(
      X3DHSenderResult(
        ephemeralPublicKey: ephemeralPublicKey,
        sharedKey: sharedKey,
      ),
    );
  }

  /// Вычисляет общий секрет на стороне получателя.
  ///
  /// [bundle] — локальный ключевой бандл (с приватными ключами), привязка
  /// в нём действительна по конструкции (сгенерирован локально).
  Future<SecretKey> receiver({
    required X3DHKeyBundle bundle,
    required PublicKey senderEphemeralPublicKey,
  }) async {
    // cryptography v2.9.0 не предоставляет KeyPair.fromPrivateKeyBytes, но
    // SimpleKeyPairData реализует KeyPair и принимает сырые приватные байт
    // плюс соответствующий открытый ключ.
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

    return await _deriveSharedKey(dh2: dh2, dh3: dh3);
  }

  Future<SecretKey> _deriveSharedKey({
    required SecretKey dh2,
    required SecretKey dh3,
  }) async {
    final dh2Bytes = Uint8List.fromList(await dh2.extractBytes());
    final dh3Bytes = Uint8List.fromList(await dh3.extractBytes());
    final combined = Uint8List.fromList([...dh2Bytes, ...dh3Bytes]);
    return await _hkdf.derive(
      secret: SecretKey(combined),
      salt: Uint8List(32),
      info: Uint8List.fromList(utf8.encode('opensink/x3dh/shared-key')),
      outputLength: 32,
    );
  }

  /// Проверяет привязку SPK к IK (DESIGN.md §13.2).
  /// Возвращает false при отсутствии или неверной подписи.
  Future<bool> _verifySpkBinding(X3DHPublicBundle bundle) async {
    final signatureHex = bundle.signedPrekeySignature;
    if (signatureHex == null || signatureHex.isEmpty) {
      return false;
    }

    try {
      final signatureBytes = hexToBytes(signatureHex);
      if (signatureBytes.length != 64) {
        return false;
      }

      final spkBytes = Uint8List.fromList((bundle.signedPrekey as SimplePublicKey).bytes);
      final signingContext = Uint8List.fromList(
        utf8.encode('$_spkBindingContext|'),
      );
      final signingInput = Uint8List.fromList([...signingContext, ...spkBytes]);

      final signature = Signature(
        signatureBytes,
        publicKey: bundle.ed25519PublicKey,
      );

      return await _ed25519.verify(signingInput, signature: signature);
    } catch (_) {
      return false;
    }
  }
}

class X3DHPublicBundle {
  const X3DHPublicBundle({
    required this.identityKey,
    required this.signedPrekey,
    required this.ed25519PublicKey,
    this.signedPrekeySignature,
  });

  final PublicKey identityKey;
  final PublicKey signedPrekey;
  /// Открытый ключ Ed25519 для проверки привязки SPK (DESIGN.md §13.2).
  final PublicKey ed25519PublicKey;
  final String? signedPrekeySignature;
}

class X3DHKeyBundle {
  const X3DHKeyBundle({
    required this.identityKey,
    required this.identityPrivateKey,
    required this.signedPrekey,
    required this.signedPrekeyPrivateKey,
    required this.ed25519PublicKey,
    required this.signedPrekeySignature,
  });

  final PublicKey identityKey;
  final SecretKey identityPrivateKey;
  final PublicKey signedPrekey;
  final SecretKey signedPrekeyPrivateKey;
  /// Открытый ключ Ed25519 для проверки привязки.
  final PublicKey ed25519PublicKey;
  final String signedPrekeySignature;

  X3DHPublicBundle toPublicBundle() => X3DHPublicBundle(
        identityKey: identityKey,
        signedPrekey: signedPrekey,
        ed25519PublicKey: ed25519PublicKey,
        signedPrekeySignature: signedPrekeySignature,
      );
}

class X3DHSenderResult {
  const X3DHSenderResult({
    required this.ephemeralPublicKey,
    required this.sharedKey,
  });

  final PublicKey ephemeralPublicKey;
  final SecretKey sharedKey;
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
    info: Uint8List.fromList(
      utf8.encode('opensink/x3dh/session/sending-chain'),
    ),
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
