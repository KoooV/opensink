import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'hkdf.dart';

/// Производство ключей группы из group_secret через HKDF.
///
/// Из одного group_secret выводится три независимых ключа с разными
/// контекстами (info):
///  1. signaling topic — для подписки в Nostr-реле / трекере
///  2. signaling payload key — для AEAD-шифрования сообщений в signaling
///  3. invitation key — для шифрования приглашений в группу
class GroupSecret {
  const GroupSecret._(this._secret);

  final SecretKey _secret;

  /// Создать [GroupSecret] из shared secret.
  factory GroupSecret(SecretKey secret) => GroupSecret._(secret);

  /// Создать [GroupSecret] из случайных байт (32 байта рекомендуется).
  static Future<GroupSecret> random() async {
    final algorithm = const XChaCha20Poly1305();
    final key = await algorithm.newSecretKey();
    return GroupSecret._(key);
  }

  final _hkdf = Hkdf();

  /// Zero-filled salt (HKDF позволяет нулевую соль, если secret уже высокоэнтропный).
  static const _zeroSalt = Uint8List(32);

  /// Signaling topic (байтовый идентификатор для подписки в реле).
  Future<Uint8List> topic() async {
    return _hkdf.deriveBytes(
      secret: _secret,
      salt: _zeroSalt,
      info: SignalingTopicContext.info,
      length: 32,
    );
  }

  /// Signaling topic как hex-строка.
  Future<String> topicHex() async {
    return (await topic()).hex;
  }

  /// Ключ шифрования signaling-payload (XChaCha20-Poly1305, 256 бит).
  Future<SecretKey> signalingPayloadKey() async {
    final bytes = await _hkdf.deriveBytes(
      secret: _secret,
      salt: _zeroSalt,
      info: SignalingPayloadKeyContext.info,
      length: 32,
    );
    return SecretKey(bytes);
  }

  /// Ключ приглашений в группу (XChaCha20-Poly1305, 256 бит).
  Future<SecretKey> invitationKey() async {
    final bytes = await _hkdf.deriveBytes(
      secret: _secret,
      salt: _zeroSalt,
      info: InvitationKeyContext.info,
      length: 32,
    );
    return SecretKey(bytes);
  }

  /// Все три ключа за один вызов.
  Future<GroupKeys> allKeys() async {
    final topic = await topic();
    final signalingKey = await signalingPayloadKey();
    final invitationKey = await invitationKey();
    return GroupKeys(
      topic: topic,
      topicHex: topic.hex,
      signalingPayloadKey: signalingKey,
      invitationKey: invitationKey,
    );
  }
}

/// Набор производных ключей группы.
class GroupKeys {
  const GroupKeys({
    required this.topic,
    required this.topicHex,
    required this.signalingPayloadKey,
    required this.invitationKey,
  });

  final Uint8List topic;
  final String topicHex;
  final SecretKey signalingPayloadKey;
  final SecretKey invitationKey;
}
