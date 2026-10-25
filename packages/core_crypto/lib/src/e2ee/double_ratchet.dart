import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'package:core_domain/core_domain.dart';

import '../aead.dart';
import '../hkdf.dart';
import '../crypto_exceptions.dart';
import '../crypto_provider.dart';

/// Double Ratchet (DESIGN.md §13.3).
///
/// Цепочки ключей: корневой ключ (RK), цепочка отправки (CK-send),
/// цепочка получения (CK-recv). DH-ratchet шаг через [dhRatchetStep].
/// Пропущенные ключи в окне [maxSkip] с TTL [ttl]. Сериализация —
/// формат версии 1 ([toBytes]/[fromBytes]).
class DoubleRatchet {
  /// Версия формата сериализации.
  static const int _version = 1;

  /// Максимальное количество пропущенных ключей в окне получения.
  static const int maxSkip = 100;

  /// TTL пропущенного ключа (24 часа, DESIGN.md §13.3).
  static const Duration ttl = Duration(hours: 24);

  /// Длина фиксированной части заголовка (без опционального DH-ключа).
  static const int _fixedHeaderLength = 50; // 1+1+32+8+8

  /// Протокольный максимум номера сообщения. Защита от DoS: абсурдные
  /// значения (например 2^31) отвергаются до цикла пропуска ключей и без
  /// аллокаций в цикле.
  static const int _maxMessageNumber = 1 << 30;

  final _aead = XChaCha20Poly1305Aead();
  final _hkdf = GroupHkdf();
  final _x25519 = CryptoProvider.instance.x25519;

  final crypto_pkg.SecretKey rootKey;
  final crypto_pkg.SecretKey sendingChainKey;
  final crypto_pkg.SecretKey receivingChainKey;
  final crypto_pkg.SecretKey? dhPrivateKey;
  final crypto_pkg.PublicKey? dhPublicKey;
  final crypto_pkg.PublicKey? remoteDhPublicKey;
  final int sendingMessageCounter;
  final int receivingMessageCounter;
  final int previousChainLength;

  /// Пропущенные ключи получения: номер сообщения → запись.
  /// LinkedHashMap сохраняет порядок вставки для FIFO-вытеснения.
  final LinkedHashMap<int, _SkippedKeyEntry> skippedKeys;

  DoubleRatchet({
    required this.rootKey,
    required this.sendingChainKey,
    required this.receivingChainKey,
    this.dhPrivateKey,
    this.dhPublicKey,
    this.remoteDhPublicKey,
    this.sendingMessageCounter = 0,
    this.receivingMessageCounter = 0,
    this.previousChainLength = 0,
    LinkedHashMap<int, _SkippedKeyEntry>? skippedKeys,
  }) : skippedKeys = skippedKeys ?? LinkedHashMap<int, _SkippedKeyEntry>();

  /// Шифрует [plaintext] и возвращает полный wire format
  /// (DESIGN.md §13.3, заголовок версии 1):
  ///
  /// ```
  /// version(1) || flags(1) || ephemeralPK(32) || messageNumber(8 LE)
  /// || prevChainLength(8 LE) || [dhPublicKey(32) optional] ||
  /// nonce(24) || ciphertext || mac(16)
  /// ```
  ///
  /// Если передан [remotePublicKey], выполняется [dhRatchetStep] перед
  /// шифрованием, флаг ratchet-шага устанавливается, новый открытый DH-ключ
  /// включается в опциональное поле заголовка.
  Future<CryptoResult<DoubleRatchetResult>> encrypt({
    required Uint8List plaintext,
    Uint8List? associatedData,
    crypto_pkg.PublicKey? remotePublicKey,
  }) async {
    var state = this;
    var flags = 0;
    Uint8List? optionalDhPublicKeyBytes;

    // Опциональный DH-ratchet шаг перед шифрованием.
    if (remotePublicKey != null && state.dhPrivateKey != null) {
      final stepResult = await state.dhRatchetStep(remotePublicKey);
      if (stepResult.isErr) {
        return const Err(KeyDerivationFailed());
      }
      state = stepResult.unwrap();
      flags = 0x01;
      final optPk = state.dhPublicKey;
      if (optPk != null) {
        optionalDhPublicKeyBytes = Uint8List.fromList(
          (optPk as crypto_pkg.SimplePublicKey).bytes,
        );
      }
    }

    // KDF_CK: chain key → 64 байт → message key (32) + next chain key (32).
    // Один вызов HKDF с outputLength=64, затем split. Два вызова с
    // одинаковым info дали бы одинаковые 32 байта (messageKey == chainKey),
    // что ломает forward secrecy.
    final ckBytes = await _hkdf.deriveBytes(
      secret: state.sendingChainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(
        utf8.encode('opensink/double-ratchet/chain-key'),
      ),
      length: 64,
    );
    final messageKey = crypto_pkg.SecretKey(ckBytes.sublist(0, 32));
    final nextSendingChainKey = crypto_pkg.SecretKey(ckBytes.sublist(32, 64));

    // Заголовок.
    final ephemeralPkBytes = state.dhPublicKey != null
        ? Uint8List.fromList(
            (state.dhPublicKey! as crypto_pkg.SimplePublicKey).bytes,
          )
        : Uint8List(32);
    final messageNumberBytes = _uint64ToBytesLe(state.sendingMessageCounter);
    final prevChainLengthBytes = _uint64ToBytesLe(state.previousChainLength);

    final hasOptional = optionalDhPublicKeyBytes != null;
    final headerLength = _fixedHeaderLength + (hasOptional ? 32 : 0);
    final header = Uint8List(headerLength);
    header[0] = _version;
    header[1] = flags;
    header.setRange(2, 34, ephemeralPkBytes);
    header.setRange(34, 42, messageNumberBytes);
    header.setRange(42, 50, prevChainLengthBytes);
    if (hasOptional) {
      header.setRange(50, 82, optionalDhPublicKeyBytes);
    }

    final aad = Uint8List.fromList([...header, ...?associatedData]);

    final encrypted = await _aead.encrypt(
      key: messageKey,
      plaintext: plaintext,
      aad: aad,
    );
    if (encrypted.isErr) {
      return const Err(EncryptionFailed());
    }

    final payload = encrypted.unwrap(); // nonce(24) || ciphertext || mac(16)

    final wireFormat = Uint8List(headerLength + payload.length);
    wireFormat.setRange(0, headerLength, header);
    wireFormat.setRange(headerLength, wireFormat.length, payload);

    final nextState = DoubleRatchet(
      rootKey: state.rootKey,
      sendingChainKey: nextSendingChainKey,
      receivingChainKey: state.receivingChainKey,
      dhPrivateKey: state.dhPrivateKey,
      dhPublicKey: state.dhPublicKey,
      remoteDhPublicKey: state.remoteDhPublicKey,
      sendingMessageCounter: state.sendingMessageCounter + 1,
      receivingMessageCounter: state.receivingMessageCounter,
      previousChainLength: state.previousChainLength,
      skippedKeys: LinkedHashMap.from(state.skippedKeys),
    );

    return Ok(
      DoubleRatchetResult(
        wireFormat: wireFormat,
        messageKey: messageKey,
        nextState: nextState,
      ),
    );
  }

  /// Расшифровывает [data] (полный wire format от [encrypt]).
  ///
  /// Парсит заголовок, при флаге ratchet-шага выполняет [dhRatchetStep]
  /// с опциональным открытым ключом собеседника, выводит ключ сообщения
  /// из цепочки получения или из пропущенных, расшифровывает AEAD.
  /// Ошибки возвращаются как [DecryptionFailed] — исключения не
  /// выбрасываются на некорректный ввод.
  Future<CryptoResult<DoubleRatchetResult>> decrypt({
    required Uint8List data,
    Uint8List? associatedData,
  }) async {
    if (data.length < _fixedHeaderLength + 24 + 16) {
      return const Err(DecryptionFailed());
    }

    final version = data[0];
    if (version != _version) {
      return const Err(DecryptionFailed());
    }

    final flags = data[1];
    final hasOptionalDh = (flags & 0x01) != 0;

    final ephemeralPkBytes = Uint8List.fromList(data.sublist(2, 34));
    final messageNumber = _bytesLeToUint64(data.sublist(34, 42));

    // DoS: абсурдный номер сообщения отвергается до любой аллокации в цикле.
    if (messageNumber > _maxMessageNumber) {
      return const Err(DecryptionFailed());
    }

    const optionalOffset = _fixedHeaderLength;
    final payloadOffset = optionalOffset + (hasOptionalDh ? 32 : 0);

    if (data.length < payloadOffset + 24 + 16) {
      return const Err(DecryptionFailed());
    }

    var state = this;

    // Рабочая копия skippedKeys — мутируется только здесь, применяется к
    // nextState только после успешной AEAD-расшифровки (атомарность).
    final workingSkipped = LinkedHashMap<int, _SkippedKeyEntry>.from(
      state.skippedKeys,
    );

    // Новый ключ из заголовка — сохраняется как remoteDhPublicKey на будущее.
    Uint8List? newRemoteDhPubBytes;

    // DH-ratchet шаг, если флаг установлен.
    // DH-вычисления используют УЖЕ ИЗВЕСТНЫЙ remoteDhPublicKey (state),
    // а не новый ключ из заголовка — иначе shared secret не совпадёт с
    // тем, что вычислил отправитель (по коммутативности DH: DH(A_priv, B_pub)
    // == DH(B_priv, A_pub) только для одних и тех же ключевых пар).
    // Новый ключ из заголовка сохраняется как remoteDhPublicKey на будущее.
    if (hasOptionalDh &&
        state.dhPrivateKey != null &&
        state.remoteDhPublicKey != null) {
      final newDhPublicKey = crypto_pkg.SimplePublicKey(
        Uint8List.fromList(data.sublist(optionalOffset, optionalOffset + 32)),
        type: crypto_pkg.KeyPairType.x25519,
      );
      newRemoteDhPubBytes = Uint8List.fromList(
        data.sublist(optionalOffset, optionalOffset + 32),
      );

      final stepResult = await state.dhRatchetStep(
        state.remoteDhPublicKey!,
        newRemoteDhPublicKey: newDhPublicKey,
      );
      if (stepResult.isErr) {
        return const Err(KeyDerivationFailed());
      }
      state = stepResult.unwrap();
    } else if (hasOptionalDh && state.dhPrivateKey != null) {
      // remoteDhPublicKey не известен — используем ключ из заголовка
      // (резервный вариант, не гарантирует совпадение ключей).
      final newDhPublicKey = crypto_pkg.SimplePublicKey(
        Uint8List.fromList(data.sublist(optionalOffset, optionalOffset + 32)),
        type: crypto_pkg.KeyPairType.x25519,
      );
      newRemoteDhPubBytes = Uint8List.fromList(
        data.sublist(optionalOffset, optionalOffset + 32),
      );

      final stepResult = await state.dhRatchetStep(newDhPublicKey);
      if (stepResult.isErr) {
        return const Err(KeyDerivationFailed());
      }
      state = stepResult.unwrap();
    }

    // AAD = header || associatedData.
    final headerBytes = Uint8List.fromList(data.sublist(0, payloadOffset));
    final aad = Uint8List.fromList([...headerBytes, ...?associatedData]);

    // nonce || ciphertext || mac (reassemble for _aead.decrypt).
    final nonce = Uint8List.fromList(
      data.sublist(payloadOffset, payloadOffset + 24),
    );
    final cipherText = Uint8List.fromList(
      data.sublist(payloadOffset + 24, data.length - 16),
    );
    final macBytes = Uint8List.fromList(data.sublist(data.length - 16));

    // Вывод ключа сообщения.
    late crypto_pkg.SecretKey messageKey;
    late crypto_pkg.SecretKey nextReceivingChainKey;
    bool keyFromSkipped = false;

    if (workingSkipped.containsKey(messageNumber)) {
      // Ключ из пропущенных.
      final entry = workingSkipped[messageNumber]!;
      messageKey = crypto_pkg.SecretKey(entry.key);
      nextReceivingChainKey = state.receivingChainKey;
      keyFromSkipped = true;
    } else if (messageNumber == state.receivingMessageCounter) {
      // Обычный вывод из цепочки получения.
      final derived = await _deriveChainKeys64(
        chainKey: state.receivingChainKey,
        info: 'opensink/double-ratchet/chain-key',
      );
      messageKey = crypto_pkg.SecretKey(derived.$1);
      nextReceivingChainKey = crypto_pkg.SecretKey(derived.$2);
    } else if (messageNumber > state.receivingMessageCounter) {
      // Пропускаем промежуточные ключи, сохраняем их в рабочую копию.
      final diff = messageNumber - state.receivingMessageCounter;
      if (diff > maxSkip) {
        return const Err(DecryptionFailed());
      }

      var chainKey = state.receivingChainKey;
      for (var i = 0; i < diff; i++) {
        final skippedMsgNum = state.receivingMessageCounter + i;
        final derived = await _deriveChainKeys64(
          chainKey: chainKey,
          info: 'opensink/double-ratchet/chain-key',
        );
        if (skippedMsgNum != messageNumber) {
          // Сохраняем как пропущенный (с вытеснением) в рабочей копии.
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          workingSkipped.removeWhere(
            (_, e) => nowMs - e.timestampMs > ttl.inMilliseconds,
          );
          while (workingSkipped.length >= maxSkip) {
            workingSkipped.remove(workingSkipped.keys.first);
          }
          workingSkipped[skippedMsgNum] = _SkippedKeyEntry(
            key: derived.$1,
            timestampMs: nowMs,
          );
        }
        chainKey = crypto_pkg.SecretKey(derived.$2);
      }

      final derived = await _deriveChainKeys64(
        chainKey: chainKey,
        info: 'opensink/double-ratchet/chain-key',
      );
      messageKey = crypto_pkg.SecretKey(derived.$1);
      nextReceivingChainKey = crypto_pkg.SecretKey(derived.$2);
    } else {
      // messageNumber < receivingMessageCounter и не в skippedKeys — replay.
      return const Err(DecryptionFailed());
    }

    final dataForDecrypt = Uint8List.fromList([
      ...nonce,
      ...cipherText,
      ...macBytes,
    ]);
    final decrypted = await _aead.decrypt(
      key: messageKey,
      data: dataForDecrypt,
      aad: aad,
    );

    if (decrypted.isErr) {
      return const Err(DecryptionFailed());
    }

    final plaintext = Uint8List.fromList(decrypted.unwrap());

    // Собираем обновлённые пропущенные ключи из рабочей копии.
    final updatedSkipped = LinkedHashMap<int, _SkippedKeyEntry>.from(
      workingSkipped,
    );
    updatedSkipped.remove(messageNumber);

    // remoteDhPublicKey: при ratchet-шаге — ключ из опционального поля заголовка,
    // иначе — ephemeralPkBytes (текущий ключ отправителя из фиксированной части).
    final remoteDhPub = newRemoteDhPubBytes != null
        ? crypto_pkg.SimplePublicKey(
            newRemoteDhPubBytes,
            type: crypto_pkg.KeyPairType.x25519,
          )
        : crypto_pkg.SimplePublicKey(
            ephemeralPkBytes,
            type: crypto_pkg.KeyPairType.x25519,
          );

    final nextState = DoubleRatchet(
      rootKey: state.rootKey,
      sendingChainKey: state.sendingChainKey,
      receivingChainKey: nextReceivingChainKey,
      dhPrivateKey: state.dhPrivateKey,
      dhPublicKey: state.dhPublicKey,
      remoteDhPublicKey: remoteDhPub,
      sendingMessageCounter: state.sendingMessageCounter,
      receivingMessageCounter: keyFromSkipped
          ? state.receivingMessageCounter
          : messageNumber + 1,
      previousChainLength: state.previousChainLength,
      skippedKeys: updatedSkipped,
    );

    return Ok(
      DoubleRatchetResult(
        wireFormat: plaintext,
        messageKey: messageKey,
        nextState: nextState,
      ),
    );
  }

  /// DH-ratchet шаг (DESIGN.md §13.3, KDF_RK).
  ///
  /// Вычисляет shared secret с [remotePublicKey] через X25519,
  /// производные через HKDF-SHA-256 (salt = предыдущий rootKey,
  /// info = "opensink/double-ratchet/root-key", 64 байт → rootKey + chain key),
  /// генерирует новую DH-пару. Возвращает новое состояние.
  /// [newRemoteDhPublicKey] — если задан, становится новым remoteDhPublicKey
  /// в следующем состоянии (используется при дешифровке: ключ для DH-вычислений
  /// — уже известный remoteDhPublicKey, а новый ключ из заголовка сохраняется
  /// на будущее). По умолчанию равен [remotePublicKey].
  Future<CryptoResult<DoubleRatchet>> dhRatchetStep(
    crypto_pkg.PublicKey remotePublicKey, {
    crypto_pkg.PublicKey? newRemoteDhPublicKey,
  }) async {
    if (dhPrivateKey == null) {
      return const Err(KeyDerivationFailed());
    }

    final keyPair = crypto_pkg.SimpleKeyPairData(
      await dhPrivateKey!.extractBytes(),
      publicKey: remotePublicKey as crypto_pkg.SimplePublicKey,
      type: crypto_pkg.KeyPairType.x25519,
    );

    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePublicKey,
    );
    final sharedBytes = Uint8List.fromList(await sharedSecret.extractBytes());

    final derived = await _hkdf.deriveBytes(
      secret: crypto_pkg.SecretKey(sharedBytes),
      salt: Uint8List.fromList(await rootKey.extractBytes()),
      info: Uint8List.fromList(utf8.encode('opensink/double-ratchet/root-key')),
      length: 64,
    );

    final newRootKeyBytes = derived.sublist(0, 32);
    final newChainKeyBytes = derived.sublist(32, 64);

    final newDhPair = await _x25519.newKeyPair();
    final newDhPrivateKeyBytes = await newDhPair.extractPrivateKeyBytes();
    final newDhPublicKey = await newDhPair.extractPublicKey();

    return Ok(
      DoubleRatchet(
        rootKey: crypto_pkg.SecretKey(newRootKeyBytes),
        sendingChainKey: crypto_pkg.SecretKey(newChainKeyBytes),
        receivingChainKey: crypto_pkg.SecretKey(newChainKeyBytes),
        dhPrivateKey: crypto_pkg.SecretKey(newDhPrivateKeyBytes),
        dhPublicKey: newDhPublicKey,
        remoteDhPublicKey: newRemoteDhPublicKey ?? remotePublicKey,
        sendingMessageCounter: 0,
        receivingMessageCounter: 0,
        previousChainLength: 0,
        skippedKeys: LinkedHashMap<int, _SkippedKeyEntry>(),
      ),
    );
  }

  /// Сериализует состояние в байты (формат версии 1, DESIGN.md §13.3).
  ///
  /// Формат:
  /// version(1) || rootKey(32) || sendingChainKey(32) || receivingChainKey(32)
  /// || sendingCounter(8 LE) || receivingCounter(8 LE) || previousChainLength(8 LE)
  /// || dhPrivateKey(32) || dhPublicKey(32) || remoteDhPublicKey(32)
  /// || skippedKeysCount(2 LE) || skippedKeys...
  ///
  /// Каждая запись skippedKeys: messageNumber(8 LE) || key(32) || timestamp(8 LE).
  Future<Uint8List> toBytes() async {
    final buf = <int>[];

    buf.add(_version);

    final rootBytes = Uint8List.fromList(await rootKey.extractBytes());
    final sendBytes = Uint8List.fromList(await sendingChainKey.extractBytes());
    final recvBytes = Uint8List.fromList(
      await receivingChainKey.extractBytes(),
    );
    buf.addAll(rootBytes);
    buf.addAll(sendBytes);
    buf.addAll(recvBytes);

    _assertUint32(sendingMessageCounter, 'sendingMessageCounter');
    _assertUint32(receivingMessageCounter, 'receivingMessageCounter');
    _assertUint32(previousChainLength, 'previousChainLength');
    buf.addAll(_uint64ToBytesLe(sendingMessageCounter));
    buf.addAll(_uint64ToBytesLe(receivingMessageCounter));
    buf.addAll(_uint64ToBytesLe(previousChainLength));

    final dhPrivBytes = dhPrivateKey != null
        ? Uint8List.fromList(await dhPrivateKey!.extractBytes())
        : Uint8List(32);
    final dhPubBytes = dhPublicKey != null
        ? Uint8List.fromList((dhPublicKey! as crypto_pkg.SimplePublicKey).bytes)
        : Uint8List(32);
    final remoteDhPubBytes = remoteDhPublicKey != null
        ? Uint8List.fromList(
            (remoteDhPublicKey! as crypto_pkg.SimplePublicKey).bytes,
          )
        : Uint8List(32);
    buf.addAll(dhPrivBytes);
    buf.addAll(dhPubBytes);
    buf.addAll(remoteDhPubBytes);

    buf.addAll(_uint64ToBytesLe(skippedKeys.length));
    for (final entry in skippedKeys.entries) {
      _assertUint32(entry.key, 'skippedKeys.messageNumber');
      final timestampSec = entry.value.timestampMs ~/ 1000;
      _assertUint32(timestampSec, 'skippedKeys.timestampMs');
      buf.addAll(_uint64ToBytesLe(entry.key));
      buf.addAll(entry.value.key);
      buf.addAll(_uint64ToBytesLe(timestampSec));
    }

    return Uint8List.fromList(buf);
  }

  /// Десериализует состояние из байтов (формат версии 1).
  ///
  /// Неизвестная версия → [StateError].
  static DoubleRatchet fromBytes(Uint8List data) {
    if (data.isEmpty || data[0] != _version) {
      throw StateError(
        'Unknown DoubleRatchet serialization version: '
        '${data.isEmpty ? 'empty' : data[0]}',
      );
    }

    var offset = 1;

    final rootKey = crypto_pkg.SecretKey(
      Uint8List.fromList(data.sublist(offset, offset + 32)),
    );
    offset += 32;
    final sendingChainKey = crypto_pkg.SecretKey(
      Uint8List.fromList(data.sublist(offset, offset + 32)),
    );
    offset += 32;
    final receivingChainKey = crypto_pkg.SecretKey(
      Uint8List.fromList(data.sublist(offset, offset + 32)),
    );
    offset += 32;

    final sendingCounter = _bytesLeToUint64(data.sublist(offset, offset + 8));
    _assertUint32(sendingCounter, 'sendingCounter');
    offset += 8;
    final receivingCounter = _bytesLeToUint64(data.sublist(offset, offset + 8));
    _assertUint32(receivingCounter, 'receivingCounter');
    offset += 8;
    final prevChainLength = _bytesLeToUint64(data.sublist(offset, offset + 8));
    _assertUint32(prevChainLength, 'prevChainLength');
    offset += 8;

    final dhPrivBytes = Uint8List.fromList(data.sublist(offset, offset + 32));
    offset += 32;
    final dhPubBytes = Uint8List.fromList(data.sublist(offset, offset + 32));
    offset += 32;
    final remoteDhPubBytes = Uint8List.fromList(
      data.sublist(offset, offset + 32),
    );
    offset += 32;

    final skippedCount = _bytesLeToUint64(data.sublist(offset, offset + 8))
        .toInt();
    _assertUint32(skippedCount, 'skippedCount');
    offset += 8;

    final skippedKeys = LinkedHashMap<int, _SkippedKeyEntry>();
    for (var i = 0; i < skippedCount; i++) {
      final msgNum = _bytesLeToUint64(data.sublist(offset, offset + 8)).toInt();
      _assertUint32(msgNum, 'msgNum');
      offset += 8;
      final keyBytes = Uint8List.fromList(data.sublist(offset, offset + 32));
      offset += 32;
      final timestampSec = _bytesLeToUint64(data.sublist(offset, offset + 8));
      _assertUint32(timestampSec, 'timestampMs');
      offset += 8;
      skippedKeys[msgNum] = _SkippedKeyEntry(
        key: keyBytes,
        timestampMs: timestampSec * 1000,
      );
    }

    return DoubleRatchet(
      rootKey: rootKey,
      sendingChainKey: sendingChainKey,
      receivingChainKey: receivingChainKey,
      dhPrivateKey: _isZero(dhPrivBytes)
          ? null
          : crypto_pkg.SecretKey(dhPrivBytes),
      dhPublicKey: _isZero(dhPubBytes)
          ? null
          : crypto_pkg.SimplePublicKey(
              dhPubBytes,
              type: crypto_pkg.KeyPairType.x25519,
            ),
      remoteDhPublicKey: _isZero(remoteDhPubBytes)
          ? null
          : crypto_pkg.SimplePublicKey(
              remoteDhPubBytes,
              type: crypto_pkg.KeyPairType.x25519,
            ),
      sendingMessageCounter: sendingCounter.toInt(),
      receivingMessageCounter: receivingCounter.toInt(),
      previousChainLength: prevChainLength.toInt(),
      skippedKeys: skippedKeys,
    );
  }

  @override
  String toString() =>
      'DoubleRatchet(version=$_version, sendingCounter=$sendingMessageCounter, '
      'receivingCounter=$receivingMessageCounter, '
      'skippedKeys=${skippedKeys.length}, keys=<secret>)';

  // -------------------------------------------------------------------------
  // Внутренние helpers
  // -------------------------------------------------------------------------

  Future<(Uint8List, Uint8List)> _deriveChainKeys64({
    required crypto_pkg.SecretKey chainKey,
    required String info,
  }) async {
    final ckBytes = await _hkdf.deriveBytes(
      secret: chainKey,
      salt: Uint8List(32),
      info: Uint8List.fromList(utf8.encode(info)),
      length: 64,
    );
    return (ckBytes.sublist(0, 32), ckBytes.sublist(32, 64));
  }
}

class _SkippedKeyEntry {
  const _SkippedKeyEntry({required this.key, required this.timestampMs});
  final Uint8List key;
  final int timestampMs;
}

/// Нулевой DH-ключ в сериализации означает отсутствие ключа.
bool _isZero(Uint8List bytes) {
  for (final byte in bytes) {
    if (byte != 0) return false;
  }
  return true;
}

class DoubleRatchetResult {
  const DoubleRatchetResult({
    required this.wireFormat,
    required this.messageKey,
    required this.nextState,
  });

  /// Полный wire format (отправка) или расшифрованный plaintext (получение).
  final Uint8List wireFormat;
  final crypto_pkg.SecretKey messageKey;
  final DoubleRatchet nextState;
}

// -------------------------------------------------------------------------
// Helpers для uint little-endian
//
// dart2js reprezent `int` как 32-bit signed. Сдвиги ≥ 25 бит дают
// некорректные результаты. Все счётчики Double Ratchet ограничены
// uint32 (0..0xFFFFFFFF); фактически messageNumber < 2^30
// (_maxMessageNumber). 8-байтное wire-поле кодируется как uint32 в
// младших 4 байтах LE, старшие 4 байта зарезервированы (0).
// -------------------------------------------------------------------------

/// Максимально допустимое значение счётчика (uint32).
const int _uint32Max = 0xFFFFFFFF;

/// Проверяет, что [value] помещается в uint32. Иначе — [ArgumentError].
void _assertUint32(int value, String name) {
  if (value < 0 || value > _uint32Max) {
    throw ArgumentError('$name выходит за пределы uint32: $value');
  }
}

/// Кодирует [value] (uint32) в 8 байт little-endian.
/// dart2js-безопасно: сдвиги не превышают 24 бита, каждый результат маскируется & 0xFF.
Uint8List _uint64ToBytesLe(int value) {
  _assertUint32(value, 'value');
  final bytes = Uint8List(8);
  bytes[0] = value & 0xFF;
  bytes[1] = (value >> 8) & 0xFF;
  bytes[2] = (value >> 16) & 0xFF;
  bytes[3] = (value >> 24) & 0xFF;
  // bytes[4..7] = 0 — старшие 32 бита зарезервированы.
  return bytes;
}

/// Декодирует 8 байт little-endian в int (младшие 4 байта LE).
/// dart2js представляет `int` как 32-bit signed:
/// - Значения < 2^31 → положительный int (byte 3 << 24 безопасен).
/// - Значения ≥ 2^31 → отрицательный int ( бит 31 devient sign bit),
///   практически недостижимы, так как messageNumber ограничен
///   _maxMessageNumber (2^30), а все прочие счётчики проходят
///   валидацию [_assertUint32] при записи и чтении.
int _bytesLeToUint64(Uint8List bytes) {
  return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
}
