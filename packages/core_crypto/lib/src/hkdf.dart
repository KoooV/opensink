import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto_pkg;

/// HKDF key derivation (RFC 5869) поверх [package:cryptography] v2.9.0.
class GroupHkdf {
  GroupHkdf();

  final _hmac = crypto_pkg.Hmac.sha256();

  Future<crypto_pkg.SecretKey> derive({
    required crypto_pkg.SecretKey secret,
    required Uint8List salt,
    required Uint8List info,
    required int outputLength,
  }) async {
    final algorithm = crypto_pkg.Hkdf(
      hmac: _hmac,
      outputLength: outputLength,
    );
    final derived = await algorithm.deriveKey(
      secretKey: secret,
      nonce: salt,
      info: info,
    );
    return derived;
  }

  Future<Uint8List> deriveBytes({
    required crypto_pkg.SecretKey secret,
    required Uint8List salt,
    required Uint8List info,
    required int length,
  }) async {
    final key = await derive(
      secret: secret,
      salt: salt,
      info: info,
      outputLength: length,
    );
    return Uint8List.fromList(await key.extractBytes());
  }
}

abstract class GroupKeyContext {
  const GroupKeyContext();
}

class SignalingTopicContext extends GroupKeyContext {
  const SignalingTopicContext();
  static final Uint8List info = Uint8List.fromList(
    utf8.encode('opensink/group/signaling-topic'),
  );
}

class SignalingPayloadKeyContext extends GroupKeyContext {
  const SignalingPayloadKeyContext();
  static final Uint8List info = Uint8List.fromList(
    utf8.encode('opensink/group/signaling-payload-key'),
  );
}

class InvitationKeyContext extends GroupKeyContext {
  const InvitationKeyContext();
  static final Uint8List info = Uint8List.fromList(
    utf8.encode('opensink/group/invitation-key'),
  );
}

String bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

List<int> hexToBytes(String hex) {
  return List<int>.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}
