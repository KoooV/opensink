import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import '../aead.dart';
import '../hkdf.dart';

class SenderKey {
  SenderKey({
    required this.chainKey,
    required this.iteration,
  });

  final SecretKey chainKey;
  final int iteration;

  final _aead = XChaCha20Poly1305Aead();

  Future<SenderKeyResult> encrypt({
    required Uint8List plaintext,
    Uint8List? associatedData,
  }) async {
    final hkdf = GroupHkdf();
    final mkBytes = await hkdf.deriveBytes(
      secret: chainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/sender-key/message-key'),
      ),
      length: 32,
    );
    final nextChainKey = await hkdf.deriveBytes(
      secret: chainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/sender-key/chain-key'),
      ),
      length: 32,
    );

    final messageKey = SecretKey(mkBytes);
    final encrypted = await _aead.encrypt(
      key: messageKey,
      plaintext: plaintext,
      aad: associatedData,
    );

    return SenderKeyResult(
      ciphertext: encrypted.unwrap(),
      iteration: iteration,
      nextKey: SenderKey(
        chainKey: SecretKey(nextChainKey),
        iteration: iteration + 1,
      ),
    );
  }

  static Future<Uint8List> decrypt({
    required SecretKey chainKey,
    required int expectedIteration,
    required Uint8List ciphertext,
    Uint8List? associatedData,
  }) async {
    final hkdf = GroupHkdf();
    final mkBytes = await hkdf.deriveBytes(
      secret: chainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/sender-key/message-key'),
      ),
      length: 32,
    );

    final messageKey = SecretKey(mkBytes);
    final aead = XChaCha20Poly1305Aead();
    final decrypted = await aead.decrypt(
      key: messageKey,
      data: ciphertext,
      aad: associatedData,
    );

    return decrypted.unwrap();
  }

  static Future<SenderKey> rotate() async {
    final key = await generateAeadKey();
    return SenderKey(chainKey: key, iteration: 0);
  }
}

class SenderKeyResult {
  const SenderKeyResult({
    required this.ciphertext,
    required this.iteration,
    required this.nextKey,
  });

  final Uint8List ciphertext;
  final int iteration;
  final SenderKey nextKey;
}

class SenderKeyState {
  const SenderKeyState({
    required this.senderKeys,
  });

  final Map<String, SenderKey> senderKeys;

  SenderKey keyFor(String userId) {
    return senderKeys[userId] ?? SenderKey(
      chainKey: SecretKey(Uint8List(32)),
      iteration: 0,
    );
  }

  SenderKeyState withKey(String userId, SenderKey key) {
    final updated = Map<String, SenderKey>.from(senderKeys);
    updated[userId] = key;
    return SenderKeyState(senderKeys: updated);
  }
}
