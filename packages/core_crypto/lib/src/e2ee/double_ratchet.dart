import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import '../aead.dart';
import '../hkdf.dart';

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

  final _aead = XChaCha20Poly1305Aead();

  Future<DoubleRatchetResult> encrypt({
    required Uint8List plaintext,
    Uint8List? associatedData,
  }) async {
    final hkdf = GroupHkdf();
    final mkBytes = await hkdf.deriveBytes(
      secret: sendingChainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/double-ratchet/message-key'),
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

    final encrypted = await _aead.encrypt(
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

  Future<DoubleRatchetResult> decrypt({
    required Uint8List ciphertext,
    Uint8List? associatedData,
  }) async {
    final hkdf = GroupHkdf();
    final mkBytes = await hkdf.deriveBytes(
      secret: receivingChainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/double-ratchet/message-key'),
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

    final decrypted = await _aead.decrypt(
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

  Future<DoubleRatchetResult> dhRatchetStep(PublicKey remotePublicKey) async {
    throw UnimplementedError(
      'dhRatchetStep требует X25519.sharedSecretKey с KeyPair. '
      'TODO(verify): перейти на cryptography v3.x.',
    );
  }
}

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
