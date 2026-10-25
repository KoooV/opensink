import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart' show hexDecode;
import 'package:meta/meta.dart';

/// Домен подписи инвайт-ссылки.
const String inviteLinkAuthDomain = 'opensink/group/invite-link/v1|';

/// Ошибки разбора инвайт-ссылки.
sealed class InviteLinkError {
  const InviteLinkError();

  @override
  String toString() => runtimeType.toString();
}

class MalformedInviteLink extends InviteLinkError {
  const MalformedInviteLink(this.reason);

  final String reason;

  @override
  String toString() => 'MalformedInviteLink($reason)';
}

class MissingInviteField extends InviteLinkError {
  const MissingInviteField(this.field);

  final String field;

  @override
  String toString() => 'MissingInviteField($field)';
}

/// Инвайт-ссылка: gid, genesis id, inviteId, group_secret, публичный ключ
/// админа, relay hint.
///
/// [secret] не попадает в [toString]. Утечка ссылки раскрывает секрет темы
/// signaling; для чувствительных групп нужен режим approval и ротация ключей.
@immutable
class InviteLink {
  const InviteLink({
    required this.groupId,
    required this.genesisEventId,
    required this.inviteId,
    required this.secret,
    required this.inviterId,
    required this.expiresAt,
    required this.signature,
    this.relayHint = '',
  });

  final GroupId groupId;

  /// Доверенный корень группы из ссылки.
  final EventId genesisEventId;
  final String inviteId;
  final String secret;
  final UserId inviterId;

  /// Unix ms; ссылка недействительна после этого момента.
  final int expiresAt;

  /// Ed25519-подпись инвайтера над [signingBytes].
  final String signature;
  final String relayHint;

  /// Канонические байты подписи инвайтера.
  Uint8List signingBytes() {
    final buffer = StringBuffer(inviteLinkAuthDomain)
      ..write(groupId.value)
      ..write('|')
      ..write(genesisEventId.value)
      ..write('|')
      ..write(inviteId)
      ..write('|')
      ..write(expiresAt)
      ..write('|')
      ..write(inviterId.value);
    return Uint8List.fromList(utf8.encode(buffer.toString()));
  }

  /// Проверяет подпись инвайтера; ключ берётся из [inviterId].
  Future<bool> verifySignature(Signer signer) async {
    final key = hexDecode(inviterId.value);
    if (key == null || key.length != 32 || signature.isEmpty) return false;
    return signer.verify(signingBytes(), signature, PeerId(key));
  }

  /// Подписывает новую ссылку ключом инвайтера.
  static Future<InviteLink> issue({
    required Signer signer,
    required GroupId groupId,
    required EventId genesisEventId,
    required String inviteId,
    required String secret,
    required UserId inviterId,
    required int expiresAt,
    String relayHint = '',
  }) async {
    final unsigned = InviteLink(
      groupId: groupId,
      genesisEventId: genesisEventId,
      inviteId: inviteId,
      secret: secret,
      inviterId: inviterId,
      expiresAt: expiresAt,
      signature: '',
      relayHint: relayHint,
    );
    final signature = await signer.sign(unsigned.signingBytes());
    return InviteLink(
      groupId: groupId,
      genesisEventId: genesisEventId,
      inviteId: inviteId,
      secret: secret,
      inviterId: inviterId,
      expiresAt: expiresAt,
      signature: signature,
      relayHint: relayHint,
    );
  }

  String toUriString() {
    return Uri(
      scheme: 'opensink',
      host: 'invite',
      queryParameters: {
        'gid': groupId.value,
        'gen': genesisEventId.value,
        'iid': inviteId,
        's': secret,
        'admin': inviterId.value,
        'exp': '$expiresAt',
        'sig': signature,
        if (relayHint.isNotEmpty) 'relay': relayHint,
      },
    ).toString();
  }

  static Result<InviteLink, InviteLinkError> parse(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'opensink' || uri.host != 'invite') {
      return const Err(MalformedInviteLink('scheme or host'));
    }
    final params = uri.queryParameters;
    final groupId = params['gid'];
    final genesis = params['gen'];
    final inviteId = params['iid'];
    final secret = params['s'];
    final admin = params['admin'];
    final expires = params['exp'];
    final signature = params['sig'];

    if (groupId == null || groupId.isEmpty) {
      return const Err(MissingInviteField('gid'));
    }
    if (genesis == null || genesis.isEmpty) {
      return const Err(MissingInviteField('gen'));
    }
    if (!_isHex64(genesis)) {
      return const Err(MalformedInviteLink('gen is not 64-hex'));
    }
    if (inviteId == null || inviteId.isEmpty) {
      return const Err(MissingInviteField('iid'));
    }
    if (secret == null || secret.isEmpty) {
      return const Err(MissingInviteField('s'));
    }
    if (admin == null || admin.isEmpty) {
      return const Err(MissingInviteField('admin'));
    }
    if (!_isHex64(admin)) {
      return const Err(MalformedInviteLink('admin is not 64-hex'));
    }
    if (expires == null || expires.isEmpty) {
      return const Err(MissingInviteField('exp'));
    }
    final expiresAt = int.tryParse(expires);
    if (expiresAt == null || expiresAt <= 0) {
      return const Err(MalformedInviteLink('invalid exp'));
    }
    if (signature == null || signature.isEmpty) {
      return const Err(MissingInviteField('sig'));
    }

    return Ok(
      InviteLink(
        groupId: GroupId(groupId),
        genesisEventId: EventId(genesis),
        inviteId: inviteId,
        secret: secret,
        inviterId: UserId(admin),
        expiresAt: expiresAt,
        signature: signature,
        relayHint: params['relay'] ?? '',
      ),
    );
  }

  @override
  String toString() =>
      'InviteLink(groupId=$groupId, genesisEventId=$genesisEventId, '
      'inviteId=$inviteId, secret=<hidden>, inviterId=$inviterId, '
      'expiresAt=$expiresAt, relayHint=$relayHint)';
}

bool _isHex64(String value) {
  if (value.length != 64) return false;
  for (final code in value.codeUnits) {
    final isDigit = code >= 0x30 && code <= 0x39;
    final isLower = code >= 0x61 && code <= 0x66;
    final isUpper = code >= 0x41 && code <= 0x46;
    if (!isDigit && !isLower && !isUpper) return false;
  }
  return true;
}
