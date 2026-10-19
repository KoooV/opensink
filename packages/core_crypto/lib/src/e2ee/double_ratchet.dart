import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'hkdf.dart';

/// Double Ratchet (Signal Protocol) поверх [package:cryptography].
///
/// Состояние: корневой ключ, цепочки ключей отправки/приёма, DH-пары.
/// Каждое сообщение продвигает симметрическую крышку (symmetric ratchet),
/// периодически выполняется DH-крышка с новой эфемерной парой.
///
/// Реализация упрощённая (без skipped message keys, без out-of-order доставки)
/// — достаточно для P2P мессенджера с надёжным транспортом WebRTC.
class DoubleRatchet {
  DoubleRatchet({
    required this.rootKey,
    required this.sendingChainKey,
    required this.receivingChainKey,
    this.dhPrivateKey,
    this.dhPublicKey,
    this.remoteDhPublicKey,
    this.messageCounter = 0,
    this.previousChainLength = 0,
  });

  final SecretKey rootKey;
  final SecretKey sendingChainKey;
  final SecretKey receivingChainKey;
  final SecretKey? dhPrivateKey;
  final PublicKey? dhPublicKey;
  final PublicKey? remoteDhPublicKey;
  final int messageCounter;
  final int previousChainLength;

  /// Зашифровать сообщение.
  /// Возвращает зашифрованные данные и следующее состояние.
  Future<DoubleRatchetResult> encrypt({
    required Uint8List plaintext,
    Uint8List? associatedData,
  }) async {
    // Symmetric ratchet: производим message key из цепочки отправки.
    final hkdf = Hkdf();
    final mkBytes = await hkdf.deriveBytes(
      secret: sendingChainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/double-ratchet/message-key-send'),
      ),
      length: 32,
    );
    final nextChainKey = await hkdf.deriveBytes(
      secret: sendingChainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/double-ratchet/chain-key-send'),
      ),
      length: 32,
    );

    final messageKey = SecretKey(mkBytes);
    final nextSendingChainKey = SecretKey(nextChainKey);

    final aead = XChaCha20Poly1305Aead();
    final encrypted = await aead.encrypt(
      key: messageKey,
      plaintext: plaintext,
      aad: associatedData,
    );

    final encryptedBytes = encrypted.unwrap();

    return DoubleRatchetResult(
      ciphertext: encryptedBytes,
      messageKey: messageKey,
      nextState: DoubleRatchet(
        rootKey: rootKey,
        sendingChainKey: nextSendingChainKey,
        receivingChainKey: receivingChainKey,
        dhPrivateKey: dhPrivateKey,
        dhPublicKey: dhPublicKey,
        remoteDhPublicKey: remoteDhPublicKey,
        messageCounter: messageCounter + 1,
        previousChainLength: previousChainLength,
      ),
    );
  }

  /// Расшифровать сообщение.
  Future<DoubleRatchetResult> decrypt({
    required Uint8List ciphertext,
    Uint8List? associatedData,
  }) async {
    final hkdf = Hkdf();
    final mkBytes = await hkdf.deriveBytes(
      secret: receivingChainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/double-ratchet/message-key-recv'),
      ),
      length: 32,
    );
    final nextChainKey = await hkdf.deriveBytes(
      secret: receivingChainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/double-ratchet/chain-key-recv'),
      ),
      length: 32,
    );

    final messageKey = SecretKey(mkBytes);
    final nextReceivingChainKey = SecretKey(nextChainKey);

    final aead = XChaCha20Poly1305Aead();
    final decrypted = await aead.decrypt(
      key: messageKey,
      data: ciphertext,
      aad: associatedData,
    );

    final plaintext = decrypted.unwrap();

    return DoubleRatchetResult(
      ciphertext: plaintext,
      messageKey: messageKey,
      nextState: DoubleRatchet(
        rootKey: rootKey,
        sendingChainKey: sendingChainKey,
        receivingChainKey: nextReceivingChainKey,
        dhPrivateKey: dhPrivateKey,
        dhPublicKey: dhPublicKey,
        remoteDhPublicKey: remoteDhPublicKey,
        messageCounter: messageCounter + 1,
        previousChainLength: previousChainLength,
      ),
    );
  }

  /// DH Ratchet step: создать новую DH paire, произвести с удалённой публичной ключом,
  /// derived новый root key и цепочки.
  Future<DoubleRatchetResult> dhRatchetStep(PublicKey remotePublicKey) async {
    final x25519 = X25519();
    final newDhPair = await x25519.newKeyPair();
    final sharedSecret = await x25519.agree(
      remotePublicKey: remotePublicKey,
      privateKey: newDhPair.privateKey,
    );
    final sharedBytes = await sharedSecret.extractBytes();

    final hkdf = Hkdf();
    final combined = Uint8List.fromList([
      ...await rootKey.extractBytes(),
      ...sharedBytes,
    ]);
    final newRootKey = await hkdf.deriveBytes(
      secret: SecretKey(combined),
      salt: Uint8List(32),
      info: Uint8List.fromList(utf8.encode('opensink/double-ratchet/root-key')),
      length: 32,
    );
    final newSendingChainKey = await hkdf.deriveBytes(
      secret: SecretKey(newRootKey),
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/double-ratchet/chain-key-send-init'),
      ),
      length: 32,
    );
    final newReceivingChainKey = await hkdf.deriveBytes(
      secret: SecretKey(newRootKey),
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/double-ratchet/chain-key-recv-init'),
      ),
      length: 32,
    );

    return DoubleRatchetResult(
      ciphertext: Uint8List(0),
      messageKey: SecretKey(Uint8List(32)),
      nextState: DoubleRatchet(
        rootKey: SecretKey(newRootKey),
        sendingChainKey: SecretKey(newSendingChainKey),
        receivingChainKey: SecretKey(newReceivingChainKey),
        dhPrivateKey: newDhPair.privateKey,
        dhPublicKey: newDhPair.publicKey,
        remoteDhPublicKey: remotePublicKey,
        messageCounter: 0,
        previousChainLength: messageCounter,
      ),
    );
  }
}

/// Результат операции Double Ratchet.
class DoubleRatchetResult {
  const DoubleRatchetResult({
    required this.ciphertext,
    required this.messageKey,
    required this.nextState,
  });

  final Uint8List ciphertext;
  final SecretKey messageKey;
  final DoubleRatchet nextState;
}
