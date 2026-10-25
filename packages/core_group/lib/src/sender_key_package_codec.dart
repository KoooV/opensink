import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart' show hexDecode;

import 'key_distributor.dart';

/// Кодек подписанного sender-key пакета для личного E2E-канала.
///
/// Канал шифрует и аутентифицирует [encode] целиком; подпись внутри пакета
/// проверяется получателем после расшифровки.
class SenderKeyPackageCodec {
  const SenderKeyPackageCodec({this.version = 1});

  final int version;

  Uint8List encode(SenderKeyPackage package) {
    final json = jsonEncode(<String, Object?>{
      'version': version,
      'groupId': package.groupId.value,
      'epoch': package.epoch,
      'sender': package.sender.value,
      'recipient': package.recipient.value,
      'keyPackage': base64Encode(package.keyPackage),
      'signature': package.signature,
    });
    return Uint8List.fromList(utf8.encode(json));
  }

  Result<SenderKeyPackage, SenderKeyPackageError> decode(
    Uint8List data, {
    int maxPackageBytes = 64 * 1024,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(data));
    } on FormatException {
      return const Err(InvalidSenderKeyPackage('malformed package'));
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != version ||
        decoded['groupId'] is! String ||
        decoded['epoch'] is! int ||
        decoded['sender'] is! String ||
        decoded['recipient'] is! String ||
        decoded['keyPackage'] is! String ||
        (decoded['signature'] != null && decoded['signature'] is! String)) {
      return const Err(InvalidSenderKeyPackage('malformed package'));
    }

    final Uint8List keyPackage;
    try {
      keyPackage = Uint8List.fromList(
        base64Decode(decoded['keyPackage'] as String),
      );
    } on FormatException {
      return const Err(InvalidSenderKeyPackage('key package is invalid'));
    }

    final signature = decoded['signature'] as String?;
    if (signature == null || signature.isEmpty) {
      return const Err(InvalidSenderKeyPackage('missing signature'));
    }
    final signatureBytes = hexDecode(signature);
    if (signatureBytes == null || signatureBytes.length != 64) {
      return const Err(InvalidSenderKeyPackage('signature is invalid'));
    }

    final package = SenderKeyPackage(
      groupId: GroupId(decoded['groupId'] as String),
      epoch: decoded['epoch'] as int,
      sender: UserId(decoded['sender'] as String),
      recipient: UserId(decoded['recipient'] as String),
      keyPackage: keyPackage,
      signature: signature,
    );
    final invalid = package.validate(maxPackageBytes: maxPackageBytes);
    if (invalid != null) return Err(invalid);
    return Ok(package);
  }
}
