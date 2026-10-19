import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Sender Keys для групповых чатов.
///
/// Каждый участник группы поддерживает цепочку ключей (sender key chain).
/// Каждое сообщение шифруется message key, производным от текущего chain key,
/// после чего chain key продвигается вперёд (ratchet).
/// При изменении состава группы (вход/выход участника) выполняется ротация:
/// отправитель генерирует новый chain key и рассылает его всем участникам
/// через зашифрованные личные каналы (Double Ratchet).
class SenderKey {
  SenderKey({
    required this.chainKey,
    required this.iteration,
  });

  final SecretKey chainKey;
  final int iteration;

  /// Зашифровать сообщение для группы.
  /// Возвращает зашифрованные данные и следующее состояние ключа.
  Future<SenderKeyResult> encrypt({
    required Uint8List plaintext,
    Uint8List? associatedData,
  }) async {
    final hkdf = Hkdf();
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
    final aead = XChaCha20Poly1305Aead();
    final encrypted = await aead.encrypt(
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

  /// Расшифровать сообщение от другого отправителя.
  /// [senderIteration] — итерация, с которой было зашифровано сообщение.
  /// Должен совпадать с текущим состоянием получателя для этого отправителя.
  static Future<Uint8List> decrypt({
    required SecretKey chainKey,
    required int expectedIteration,
    required Uint8List ciphertext,
    Uint8List? associatedData,
  }) async {
    final hkdf = Hkdf();
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

  /// Ротация ключа:.generate новый chain key.
  /// Вызывается при изменении состава группы.
  static Future<SenderKey> rotate() async {
    final aead = XChaCha20Poly1305Aead();
    final newKey = await aead.generateAeadKey();
    return SenderKey(chainKey: newKey, iteration: 0);
  }
}

/// Результат шифрования Sender Key.
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

/// Состояние sender keys для группы: по одному ключу на отправителя.
class SenderKeyState {
  const SenderKeyState({
    required this.senderKeys,
  });

  /// Отправитель (UserId) → его SenderKey.
  final Map<String, SenderKey> senderKeys;

  /// Получить ключ отправителя или сгенерировать новый.
  SenderKey keyFor(String userId) {
    return senderKeys[userId] ?? SenderKey(
      chainKey: const SecretKey(Uint8List(32)), // placeholder, будет заменён
      iteration: 0,
    );
  }

  SenderKeyState withKey(String userId, SenderKey key) {
    final updated = Map<String, SenderKey>.from(senderKeys);
    updated[userId] = key;
    return SenderKeyState(senderKeys: updated);
  }
}
