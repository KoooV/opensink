import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'package:meta/meta.dart';

import 'aead.dart';

/// Тип запечатываемого состояния E2EE.
enum StateKind {
  /// Состояние Double Ratchet (сессия между двумя пирами).
  doubleRatchet,

  /// Состояние Sender Keys (групповые сообщения).
  senderKey,
}

/// Контекст封存 состояния: связывает зашифрованный blob с его смыслом и
/// идентификатором, чтобы при открытии AAD проверялся тот же контекст.
///
/// [stateId] — peerId (hex) для Double Ratchet, `groupId|senderPeerId` для
/// Sender Keys.
@immutable
class StateVaultContext {
  const StateVaultContext({
    required this.kind,
    required this.stateId,
    this.formatVersion = 1,
  });

  final StateKind kind;
  final String stateId;
  final int formatVersion;

  int get _kindByte {
    switch (kind) {
      case StateKind.doubleRatchet:
        return 0x01;
      case StateKind.senderKey:
        return 0x02;
    }
  }
}

/// Конверт зашифрованного состояния (формат версии 1).
///
/// ```
/// version(1) || kind(1) || stateIdLen(2 LE) || stateId(stateIdLen) ||
/// nonce(24) || ciphertext || mac(16)
/// ```
///
/// `toString()` не раскрывает содержимое конверта.
@immutable
class SealedState {
  const SealedState._(this._bytes);

  final Uint8List _bytes;

  /// Создаёт конверт из сырых байт. Содержимое не проверяется здесь —
  /// проверка происходит при [StateVault.open].
  factory SealedState.fromBytes(Uint8List bytes) =>
      SealedState._(Uint8List.fromList(bytes));

  /// Версия формата конверта.
  int get version => _bytes.isEmpty ? 0 : _bytes[0];

  /// Тип состояния (kod из [StateVaultContext._kindByte]).
  int get kind => _bytes.length > 1 ? _bytes[1] : 0;

  /// Идентификатор состояния.
  String get stateId {
    if (_bytes.length < 4) return '';
    final len = (_bytes[2] | (_bytes[3] << 8));
    final start = 4;
    final end = start + len;
    if (end > _bytes.length) return '';
    return String.fromCharCodes(_bytes.sublist(start, end));
  }

  /// Сырые байты конверта (включая заголовок и AEAD-тело).
  Uint8List get bytes => Uint8List.fromList(_bytes);

  @override
  String toString() =>
      'SealedState(version=$version, kind=$kind, stateIdLength=${stateId.length}, '
      'sealedLength=${_bytes.length})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SealedState &&
          runtimeType == other.runtimeType &&
          _bytes.length == other._bytes.length &&
          _bytes.asMap().entries.every(
            (e) => e.value == other._bytes[e.key],
          );

  @override
  int get hashCode {
    var hash = 0;
    for (var i = 0; i < _bytes.length; i++) {
      hash = hash * 31 + _bytes[i];
    }
    return hash;
  }
}

sealed class StateVaultError {
  const StateVaultError();
}

/// Ключ хранилища отсутствует в SecureKeyStore (требуется первая инициализация).
class VaultKeyNotFound extends StateVaultError {
  const VaultKeyNotFound();
}

/// Не удалось запечатать состояние (ошибка AEAD или хранилища ключа).
class SealFailed extends StateVaultError {
  const SealFailed();
}

/// Не удалось вскрыть конверт (неверный ключ, повреждённый конверт, несовпадающий контекст).
class OpenFailed extends StateVaultError {
  const OpenFailed();
}

typedef VaultResult<T> = Result<T, StateVaultError>;

/// Запечатывает и вскрывает сериализованные состояния E2EE на диске.
///
/// Ключ хранилища — независимый случайный 256-битный ключ, создаётся при
/// первом вызове [seal] и хранится в [SecureKeyStore] (не выводится из
/// identity seed). Потеря ключа хранилища означает, что все сохранённые
/// сессии E2EE придётся устанавливать заново (состояние ratchet и ключи
/// сообщений расшифровать невозможно).
///
/// Формат конверта (версия 1):
///   version(1) || kind(1) || stateIdLen(2 LE) || stateId(stateIdLen) ||
///   nonce(24) || ciphertext || mac(16)
///
/// AAD = utf8("opensink/state/v1") || kind(1) || stateIdLen(2 LE) ||
///       stateId(stateIdLen) || formatVersion(1)
class StateVault {
  static const String _vaultKeyId = 'opensink_state_vault_v1';
  static const int _formatVersion = 1;
  static const String _aadPrefix = 'opensink/state/v1';

  StateVault(this._secureKeyStore, {XChaCha20Poly1305Aead? aead})
      : _aead = aead ?? XChaCha20Poly1305Aead();

  final SecureKeyStore _secureKeyStore;
  final XChaCha20Poly1305Aead _aead;

  /// Запечатывает [plaintext] (сериализованное состояние) в конверт.
  ///
  /// Ключ хранилища загружается из [SecureKeyStore], при отсутствии —
  /// генерируется новый случайный 256-битный ключ и сохраняется.
  Future<VaultResult<SealedState>> seal(
    Uint8List plaintext,
    StateVaultContext context,
  ) async {
    final keyResult = await _vaultKey();
    if (keyResult.isErr) {
      return Err(keyResult.unwrapErr());
    }

    final aad = _buildAad(context);
    final encrypted = await _aead.encrypt(
      key: keyResult.unwrap(),
      plaintext: plaintext,
      aad: aad,
    );
    if (encrypted.isErr) {
      return const Err(SealFailed());
    }

    final body = encrypted.unwrap(); // nonce(24) || ciphertext || mac(16)
    final envelope = <int>[];
    envelope.add(_formatVersion);
    envelope.add(context._kindByte);
    final stateIdBytes = utf8.encode(context.stateId);
    envelope.addAll(_uint16Le(stateIdBytes.length));
    envelope.addAll(stateIdBytes);
    envelope.addAll(body);

    return Ok(SealedState.fromBytes(Uint8List.fromList(envelope)));
  }

  /// Расшифровывает [sealed] и возвращает исходные байты состояния.
  ///
  /// Несовпадение контекста (kind, stateId, formatVersion), повреждённый
  /// конверт или неверный ключ → `Err(OpenFailed)`.
  Future<VaultResult<Uint8List>> open(
    SealedState sealed,
    StateVaultContext context,
  ) async {
    final keyResult = await _vaultKey();
    if (keyResult.isErr) {
      return Err(keyResult.unwrapErr());
    }

    final aad = _buildAad(context);
    final stateIdBytes = utf8.encode(context.stateId);
    final headerLength = 4 + stateIdBytes.length;

    if (sealed.bytes.length < headerLength + 24 + 16) {
      return const Err(OpenFailed());
    }

    // Проверка заголовка конверта перед расшифровкой: версия, kind и
    // stateId должны совпадать с ожидаемым контекстом. Это обнаруживает
    // подмену байтов заголовка (version, kind, stateIdLen, stateId), которые
    // не покрываются AEAD-телом, но покрываются AAD только если они берутся
    // из контекста, а не из конверта.
    if (sealed.version != _formatVersion) {
      return const Err(OpenFailed());
    }
    if (sealed.kind != context._kindByte) {
      return const Err(OpenFailed());
    }
    if (sealed.stateId != context.stateId) {
      return const Err(OpenFailed());
    }

    final body = sealed.bytes.sublist(headerLength);
    final decrypted = await _aead.decrypt(
      key: keyResult.unwrap(),
      data: body,
      aad: aad,
    );
    if (decrypted.isErr) {
      return const Err(OpenFailed());
    }

    return Ok(decrypted.unwrap());
  }

  /// Собирает AAD для шифрования/расшифровки.
  ///
  /// AAD = utf8("opensink/state/v1") || kind(1) || stateIdLen(2 LE) ||
  ///       stateId(stateIdLen) || context.formatVersion(1)
  Uint8List _buildAad(StateVaultContext context) {
    final aad = <int>[];
    aad.addAll(utf8.encode(_aadPrefix));
    aad.add(context._kindByte);
    final stateIdBytes = utf8.encode(context.stateId);
    aad.addAll(_uint16Le(stateIdBytes.length));
    aad.addAll(stateIdBytes);
    aad.add(context.formatVersion);
    return Uint8List.fromList(aad);
  }

  /// Получает ключ хранилища из SecureKeyStore. При отсутствии — генерирует
  /// новый случайный 256-битный ключ и сохраняет его.
  Future<VaultResult<crypto_pkg.SecretKey>> _vaultKey() async {
    final loadResult = await _secureKeyStore.loadKey(_vaultKeyId);
    if (loadResult.isOk) {
      final bytes = loadResult.unwrap();
      return Ok(crypto_pkg.SecretKey(Uint8List.fromList(bytes)));
    }
    final err = loadResult.unwrapErr();
    if (err is! IdentityNotFound) {
      // Инфраструктурная ошибка — пробрасываем как неудачу.
      return const Err(OpenFailed());
    }

    // Генерируем новый ключ хранилища (не выводится из identity seed).
    final key = await generateAeadKey();
    final keyBytes = Uint8List.fromList(await key.extractBytes());
    final storeResult = await _secureKeyStore.storeKey(_vaultKeyId, keyBytes);
    if (storeResult.isErr) {
      return const Err(SealFailed());
    }
    return Ok(key);
  }

  static List<int> _uint16Le(int value) => [value & 0xFF, (value >> 8) & 0xFF];
}
