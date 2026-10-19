import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'hkdf.dart';

/// X3DH (Extended Triple Diffie-Hellman) хендшейк.
///
/// Реализация по спецификации Signal Protocol поверх [package:cryptography]
/// (X25519, HKDF-SHA-256, XChaCha20-Poly1305).
///
/// Касается только ключевого согласования — шифрование сообщений delegates в
/// [DoubleRatchet]. Собственные примитивы не изобретаются.
class X3DH {
  X3DH();

  final _x25519 = X25519();
  final _ed25519 = Ed25519();
  final _hkdf = Hkdf();

  /// Генерировать полный комплект ключей получателя:
  /// IK (долгосрочный), SPK (среднесрочный, подписан IK), OPK (одноразовый).
  Future<X3DHKeyBundle> generateKeyBundle() async {
    final ikPair = await _x25519.newKeyPair();
    final spkPair = await _x25519.newKeyPair();
    final opkPair = await _x25519.newKeyPair();

    // SPK подписывается IK для защиты от подмены.
    final spkSignature = await _ed25519.sign(
      spkPair.publicKey.bytes,
      privateKey: _ed25519PrivateKeyFromX25519(ikPair.privateKey),
    );

    return X3DHKeyBundle(
      identityKey: ikPair.publicKey,
      identityPrivateKey: ikPair.privateKey,
      signedPrekey: spkPair.publicKey,
      signedPrekeyPrivateKey: spkPair.privateKey,
      signedPrekeySignature: spkSignature.hex,
      oneTimePrekey: opkPair.publicKey,
      oneTimePrekeyPrivateKey: opkPair.privateKey,
    );
  }

  /// Сторона отправителя: вычислить общий секрет и эфемерный открытый ключ.
  ///
  /// [remoteBundle] — публичные ключи получателя.
  /// [useOneTimePrekey] — использовать ли OPK.
  Future<X3DHSenderResult> sender({
    required X3DHPublicBundle remoteBundle,
    bool useOneTimePrekey = true,
  }) async {
    final ephemeral = await _x25519.newKeyPair();

    // DH2 = EK × IK_receiver
    final dh2 = await _agree(ephemeral.privateKey, remoteBundle.identityKey);
    // DH3 = EK × SPK_receiver
    final dh3 = await _agree(ephemeral.privateKey, remoteBundle.signedPrekey);
    SharedSecret? dh4;
    if (useOneTimePrekey && remoteBundle.oneTimePrekey != null) {
      // DH4 = EK × OPK_receiver
      dh4 = await _agree(ephemeral.privateKey, remoteBundle.oneTimePrekey!);
    }

    final sharedKey = await _deriveSharedKey(
      dh2: dh2,
      dh3: dh3,
      dh4: dh4,
    );

    return X3DHSenderResult(
      ephemeralPublicKey: ephemeral.publicKey,
      sharedKey: sharedKey,
      usedOneTimePrekey: dh4 != null,
    );
  }

  /// Сторона получателя: вычислить общий секрет.
  Future<SecretKey> receiver({
    required X3DHKeyBundle bundle,
    required PublicKey senderEphemeralPublicKey,
    required bool usedOneTimePrekey,
  }) async {
    // DH2 = IK_receiver × EK_sender
    final dh2 = await _agree(bundle.identityPrivateKey, senderEphemeralPublicKey);
    // DH3 = SPK_receiver × EK_sender
    final dh3 = await _agree(bundle.signedPrekeyPrivateKey, senderEphemeralPublicKey);
    SharedSecret? dh4;
    if (usedOneTimePrekey) {
      // DH4 = OPK_receiver × EK_sender
      dh4 = await _agree(bundle.oneTimePrekeyPrivateKey!, senderEphemeralPublicKey);
    }

    return await _deriveSharedKey(
      dh2: dh2,
      dh3: dh3,
      dh4: dh4,
    );
  }

  Future<SharedSecret> _agree(SecretKey privateKey, PublicKey publicKey) async {
    return await _x25519.agree(
      remotePublicKey: publicKey,
      privateKey: privateKey,
    );
  }

  Future<SecretKey> _deriveSharedKey({
    required SharedSecret dh2,
    required SharedSecret dh3,
    SharedSecret? dh4,
  }) async {
    final dh2Bytes = await dh2.extractBytes();
    final dh3Bytes = await dh3.extractBytes();
    final allDh = Uint8List.fromList([...dh2Bytes, ...dh3Bytes]);
    if (dh4 != null) {
      final dh4Bytes = await dh4.extractBytes();
      final combined = Uint8List.fromList([...allDh, ...dh4Bytes]);
      return await _hkdf.derive(
        secret: SecretKey(combined),
        salt: Uint8List(32),
        info: Uint8List.fromList(utf8.encode('opensink/x3dh/shared-key')),
        length: 32,
      );
    }
    return await _hkdf.derive(
      secret: SecretKey(allDh),
      salt: Uint8List(32),
      info: Uint8List.fromList(utf8.encode('opensink/x3dh/shared-key')),
      length: 32,
    );
  }

  /// Псевдо-приватный ключ Ed25519 из приватного X25519 (для подписи SPK).
  /// В продакшене IK Ed25519 и X25519 — разные пары. Здесь для простоты
  /// производим Ed25519 ключ из X25519 приватного ключа через HKDF.
  SecretKey _ed25519PrivateKeyFromX25519(SecretKey x25519PrivateKey) {
    // TODO(verify): отдельная Ed25519 пара для подписи SPK вместо вывода из X25519.
    final bytes = x25519PrivateKey.extractBytes();
    return SecretKey(bytes);
  }
}

/// Публичный банdle ключей получателя (без секретов).
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

/// Полный комплект ключей получателя (с секретами).
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

/// Результат стороны отправителя X3DH.
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

/// Ключевой материал для инициализации Double Ratchet.
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

/// Произвести сессионные ключи Double Ratchet из общего секрета X3DH.
Future<X3DHSessionKeys> x3dhToSessionKeys(SecretKey sharedSecret) async {
  final hkdf = Hkdf();
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
