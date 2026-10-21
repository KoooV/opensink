import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'package:core_domain/core_domain.dart';
import '../aead.dart';
import '../hkdf.dart';
import '../crypto_exceptions.dart';

/// Sender Keys для групповых сообщений (DESIGN.md §13.4).
///
/// Каждый SenderKey содержит цепочку ключей, ключ подписи Ed25519,
/// номер итерации, groupId и senderPeerId. Сообщения подписываются;
/// подпись покрывает ciphertext || заголовок (groupId, senderPeerId, sequence).
class SenderKey {
  SenderKey({
    required this.chainKey,
    required this.signingKeyPair,
    required this.sequenceNumber,
    required this.groupId,
    required this.senderPeerId,
  });

  final crypto_pkg.SecretKey chainKey;
  final crypto_pkg.KeyPair signingKeyPair;
  final int sequenceNumber;
  final String groupId;
  final String senderPeerId;

  final _aead = XChaCha20Poly1305Aead();

  /// Шифрует [plaintext] и подписывает результат.
  ///
  /// Возвращает зашифрованные данные, подпись и следующее состояние ключа.
  Future<CryptoResult<SenderKeyResult>> encrypt({
    required Uint8List plaintext,
    Uint8List? associatedData,
  }) async {
    // KDF: chain key → message key + next chain key.
    final hkdf = GroupHkdf();
    final mkBytes = await hkdf.deriveBytes(
      secret: chainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(utf8.encode('opensink/sender-key/message-key')),
      length: 32,
    );
    final nextCkBytes = await hkdf.deriveBytes(
      secret: chainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(utf8.encode('opensink/sender-key/chain-key')),
      length: 32,
    );

    final messageKey = crypto_pkg.SecretKey(mkBytes);
    final nextChainKey = crypto_pkg.SecretKey(nextCkBytes);

    // Заголовок сообщения.
    final header = Uint8List.fromList(
      utf8.encode('groupId=$groupId|sender=$senderPeerId|seq=$sequenceNumber'),
    );

    final aad = Uint8List.fromList([...header, ...?associatedData]);

    final encrypted = await _aead.encrypt(
      key: messageKey,
      plaintext: plaintext,
      aad: aad,
    );
    if (encrypted.isErr) {
      return const Err(EncryptionFailed());
    }

    final ciphertext = encrypted.unwrap(); // nonce(24) || ciphertext || mac(16)

    // Подпись: подписываем ciphertext || header.
    final signInput = Uint8List.fromList([...ciphertext, ...header]);
    final signature = await crypto_pkg.Ed25519().sign(
      signInput,
      keyPair: signingKeyPair,
    );

    return Ok(
      SenderKeyResult(
        ciphertext: ciphertext,
        signature: Uint8List.fromList(signature.bytes),
        iteration: sequenceNumber,
        nextKey: SenderKey(
          chainKey: nextChainKey,
          signingKeyPair: signingKeyPair,
          sequenceNumber: sequenceNumber + 1,
          groupId: groupId,
          senderPeerId: senderPeerId,
        ),
      ),
    );
  }

  /// Расшифровывает и проверяет подпись.
  ///
  /// Возвращает ошибку при неверной подписи, неверной итерации или
  /// неудачной расшифровке — без исключений.
  static Future<CryptoResult<Uint8List>> decrypt({
    required crypto_pkg.SecretKey chainKey,
    required crypto_pkg.PublicKey signingPublicKey,
    required int expectedIteration,
    required Uint8List ciphertext, // nonce(24) || ciphertext || mac(16)
    required Uint8List signature, // 64 байта Ed25519
    required String groupId,
    required String senderPeerId,
    Uint8List? associatedData,
  }) async {
    final header = Uint8List.fromList(
      utf8.encode('groupId=$groupId|sender=$senderPeerId|seq=$expectedIteration'),
    );

    // 1. Проверка подписи перед любыми другими операциями.
    final signInput = Uint8List.fromList([...ciphertext, ...header]);
    try {
      final sig = crypto_pkg.Signature(
        signature,
        publicKey: signingPublicKey,
      );
      final valid = await crypto_pkg.Ed25519().verify(
        signInput,
        signature: sig,
      );
      if (!valid) {
        return const Err(InvalidSignature());
      }
    } catch (_) {
      return const Err(InvalidSignature());
    }

    // 2. Вывод ключа сообщения из chain key.
    final hkdf = GroupHkdf();
    final mkBytes = await hkdf.deriveBytes(
      secret: chainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(utf8.encode('opensink/sender-key/message-key')),
      length: 32,
    );
    final messageKey = crypto_pkg.SecretKey(mkBytes);

    // 3. Расшифровка.
    final aad = Uint8List.fromList([...header, ...?associatedData]);
    final decrypted = await XChaCha20Poly1305Aead().decrypt(
      key: messageKey,
      data: ciphertext,
      aad: aad,
    );

    if (decrypted.isErr) {
      return const Err(DecryptionFailed());
    }

    return Ok(decrypted.unwrap());
  }

  /// Ротация: генерирует новую цепочку ключей и новую пару подписи.
  static Future<SenderKey> rotate({
    required String groupId,
    required String senderPeerId,
  }) async {
    final chainKey = await generateAeadKey();
    final signingKeyPair = await crypto_pkg.Ed25519().newKeyPair();
    return SenderKey(
      chainKey: chainKey,
      signingKeyPair: signingKeyPair,
      sequenceNumber: 0,
      groupId: groupId,
      senderPeerId: senderPeerId,
    );
  }

  /// Открытый ключ подписи.
  Future<crypto_pkg.PublicKey> getSigningPublicKey() async {
    return await signingKeyPair.extractPublicKey();
  }
}

class SenderKeyResult {
  const SenderKeyResult({
    required this.ciphertext,
    required this.signature,
    required this.iteration,
    required this.nextKey,
  });

  final Uint8List ciphertext;
  final Uint8List signature;
  final int iteration;
  final SenderKey nextKey;
}

/// Состояние набора sender keys для группы (DESIGN.md §13.4).
///
/// Отслеживает ключи по senderPeerId и обеспечивает защиту от replay
/// в рамках окна в 100 номеров.
class SenderKeyState {
  SenderKeyState({
    required this.senderKeys,
    this.lastAcceptedSequence = const {},
    this.acceptedSequences = const {},
  });

  /// Ключи по senderPeerId.
  final Map<String, SenderKey> senderKeys;

  /// Последний принятый номер итерации по senderPeerId.
  final Map<String, int> lastAcceptedSequence;

  /// Принятые номера итераций в рамках окна (replay protection).
  /// Ключ: senderPeerId → множество номеров.
  final Map<String, Set<int>> acceptedSequences;

  static const int _maxWindow = 100;

  /// Абсолютный максимум номера итерации. Защита от DoS: скачок на
  /// огромное значение (например 2^31) отклоняется до вычислений, чтобы
  /// атакующий не мог перезаписать `lastAcceptedSequence` и отменить все
  /// последующие легитимные сообщения.
  static const int _maxSequence = 1 << 30;

  /// Возвращает ключ для [senderPeerId] или placeholder при отсутствии.
  SenderKey keyFor(String senderPeerId) {
    return senderKeys[senderPeerId] ?? _placeholder(senderPeerId);
  }

  static SenderKey _placeholder(String senderPeerId) {
    return SenderKey(
      chainKey: crypto_pkg.SecretKey(Uint8List(32)),
      signingKeyPair: crypto_pkg.SimpleKeyPairData(
        Uint8List(32),
        publicKey: crypto_pkg.SimplePublicKey(
          Uint8List(32),
          type: crypto_pkg.KeyPairType.ed25519,
        ),
        type: crypto_pkg.KeyPairType.ed25519,
      ),
      sequenceNumber: 0,
      groupId: '',
      senderPeerId: senderPeerId,
    );
  }

  /// Добавляет/заменяет ключ для [senderPeerId].
  SenderKeyState withKey(String senderPeerId, SenderKey key) {
    final updated = Map<String, SenderKey>.from(senderKeys);
    updated[senderPeerId] = key;
    return SenderKeyState(
      senderKeys: updated,
      lastAcceptedSequence: lastAcceptedSequence,
      acceptedSequences: acceptedSequences,
    );
  }

  /// Обновляет состояние после принятия номера итерации.
  ///
  /// Возвращает результат с флагом accepted и обновлённым состоянием.
  /// Повтор или слишком старый номер → accepted = false.
  SenderKeyStateUpdate acceptSequence(String senderPeerId, int sequenceNumber) {
    // DoS: огромный номер итерации отвергается до вычислений.
    if (sequenceNumber > _maxSequence) {
      return SenderKeyStateUpdate(
        accepted: false,
        state: this,
      );
    }

    final last = lastAcceptedSequence[senderPeerId] ?? -1;
    final accepted = acceptedSequences[senderPeerId] ?? <int>{};

    if (accepted.contains(sequenceNumber) || sequenceNumber <= last) {
      return SenderKeyStateUpdate(
        accepted: false,
        state: this,
      );
    }

    final updatedAccepted = Set<int>.from(accepted);
    updatedAccepted.add(sequenceNumber);
    while (updatedAccepted.length > _maxWindow) {
      updatedAccepted.remove(updatedAccepted.first);
    }

    final updatedLast = Map<String, int>.from(lastAcceptedSequence);
    updatedLast[senderPeerId] = sequenceNumber;

    final updatedAcceptedMap = Map<String, Set<int>>.from(acceptedSequences);
    updatedAcceptedMap[senderPeerId] = updatedAccepted;

    return SenderKeyStateUpdate(
      accepted: true,
      state: SenderKeyState(
        senderKeys: senderKeys,
        lastAcceptedSequence: updatedLast,
        acceptedSequences: updatedAcceptedMap,
      ),
    );
  }
}

class SenderKeyStateUpdate {
  const SenderKeyStateUpdate({
    required this.accepted,
    required this.state,
  });

  final bool accepted;
  final SenderKeyState state;
}

