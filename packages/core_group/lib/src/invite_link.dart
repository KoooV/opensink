import 'package:core_domain/core_domain.dart';
import 'package:meta/meta.dart';

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

/// Инвайт-ссылка: gid, inviteId, group_secret, публичный ключ админа, relay hint.
///
/// [secret] не попадает в [toString]. Утечка ссылки раскрывает секрет темы
/// signaling; для чувствительных групп нужен режим approval и ротация ключей.
@immutable
class InviteLink {
  const InviteLink({
    required this.groupId,
    required this.inviteId,
    required this.secret,
    required this.inviterId,
    this.relayHint = '',
  });

  final GroupId groupId;
  final String inviteId;
  final String secret;
  final UserId inviterId;
  final String relayHint;

  String toUriString() {
    return Uri(
      scheme: 'opensink',
      host: 'invite',
      queryParameters: {
        'gid': groupId.value,
        'iid': inviteId,
        's': secret,
        'admin': inviterId.value,
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
    final inviteId = params['iid'];
    final secret = params['s'];
    final admin = params['admin'];

    if (groupId == null || groupId.isEmpty) {
      return const Err(MissingInviteField('gid'));
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

    return Ok(
      InviteLink(
        groupId: GroupId(groupId),
        inviteId: inviteId,
        secret: secret,
        inviterId: UserId(admin),
        relayHint: params['relay'] ?? '',
      ),
    );
  }

  @override
  String toString() =>
      'InviteLink(groupId=$groupId, inviteId=$inviteId, '
      'secret=<hidden>, inviterId=$inviterId, relayHint=$relayHint)';
}
