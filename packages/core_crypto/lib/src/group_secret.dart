import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'hkdf.dart';
import 'crypto_provider.dart';

class GroupSecret {
  GroupSecret(this._secret);

  final SecretKey _secret;

  static Future<GroupSecret> random() async {
    final key = await CryptoProvider.instance.aesGcm(secretKeyLength: 32).newSecretKey();
    return GroupSecret(key);
  }

  final _hkdf = GroupHkdf();

  static final _zeroSalt = Uint8List(32);

  Future<Uint8List> topic() async {
    return _hkdf.deriveBytes(
      secret: _secret,
      salt: _zeroSalt,
      info: GroupKeyContext.signalingTopic.info,
      length: 32,
    );
  }

  Future<String> topicHex() async {
    return bytesToHex(await topic());
  }

  Future<SecretKey> signalingPayloadKey() async {
    final bytes = await _hkdf.deriveBytes(
      secret: _secret,
      salt: _zeroSalt,
      info: GroupKeyContext.signalingPayloadKey.info,
      length: 32,
    );
    return SecretKey(bytes);
  }

  Future<SecretKey> invitationKey() async {
    final bytes = await _hkdf.deriveBytes(
      secret: _secret,
      salt: _zeroSalt,
      info: GroupKeyContext.invitationKey.info,
      length: 32,
    );
    return SecretKey(bytes);
  }

  Future<GroupKeys> allKeys() async {
    final topicBytes = await topic();
    final signalingKey = await signalingPayloadKey();
    final invitationKeyDerived = await invitationKey();
    return GroupKeys(
      topic: topicBytes,
      topicHex: bytesToHex(topicBytes),
      signalingPayloadKey: signalingKey,
      invitationKey: invitationKeyDerived,
    );
  }

  @override
  String toString() => 'GroupSecret(<secret>)';
}

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

  @override
  String toString() =>
      'GroupKeys(topicHex=$topicHex, signalingPayloadKey=<secret>, invitationKey=<secret>)';
}
