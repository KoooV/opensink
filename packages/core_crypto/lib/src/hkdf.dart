import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';
import 'crypto_exceptions.dart';

/// HKDF key derivation (RFC 5869) поверх [package:cryptography].
///
/// Используется для выработки нескольких ключей из одного group_secret с
/// разными контекстами (info): topic для signaling, ключ шифрования payload,
/// ключ приглашений. Разные info гарантируют криптографическую независимость
/// производных ключей.
class Hkdf {
  Hkdf();

  final _sha256 = const Sha256();

  /// Производит [length] байт ключа из [secret] с солью [salt] и контекстом [info].
  Future<SecretKey> derive({
    required SecretKey secret,
    required Uint8List salt,
    required Uint8List info,
    required int length,
  }) async {
    try {
      final algorithm = Hkdf(
        hashAlgorithm: _sha256,
        salt: salt,
        info: info,
      );
      return await algorithm.deriveKey(
        secretKey: secret,
        length: length,
      );
    } on Exception {
      throw const KeyDerivationFailed();
    }
  }

  /// Производит сырые байты ключа (не SecretKey).
  Future<Uint8List> deriveBytes({
    required SecretKey secret,
    required Uint8List salt,
    required Uint8List info,
    required int length,
  }) async {
    final key = await derive(
      secret: secret,
      salt: salt,
      info: info,
      length: length,
    );
    return key.extractBytes();
  }
}

/// Контексты (info) для HKDF-производных ключей группы.
abstract class GroupKeyContext {
  const GroupKeyContext();
}

class SignalingTopicContext extends GroupKeyContext {
  const SignalingTopicContext();
  static const Uint8List info = Uint8List.fromList(
    utf8.encode('opensink/group/signaling-topic'),
  );
}

class SignalingPayloadKeyContext extends GroupKeyContext {
  const SignalingPayloadKeyContext();
  static const Uint8List info = Uint8List.fromList(
    utf8.encode('opensink/group/signaling-payload-key'),
  );
}

class InvitationKeyContext extends GroupKeyContext {
  const InvitationKeyContext();
  static const Uint8List info = Uint8List.fromList(
    utf8.encode('opensink/group/invitation-key'),
  );
}
