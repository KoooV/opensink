import 'package:core_domain/core_domain.dart';

/// Проверка доказательства владения секретом инвайта.
///
/// Реализация в приложении считает HMAC по
/// [inviteProofMessage] ключом `invitationKey` из `GroupSecret`.
/// В `core_group` нет секретов, поэтому проверка инжектируется.
abstract interface class InviteProofVerifier {
  bool verify({
    required GroupId groupId,
    required String inviteId,
    required UserId userId,
    required String proof,
  });
}

/// In-memory fake для тестов: принимает только явно разрешённые тройки.
class InMemoryInviteProofVerifier implements InviteProofVerifier {
  InMemoryInviteProofVerifier({
    Iterable<(GroupId, String, UserId, String)> grants = const [],
  }) : _grants = {
         for (final (groupId, inviteId, userId, proof) in grants)
           (groupId.value, inviteId, userId.value, proof),
       };

  final Set<(String, String, String, String)> _grants;

  void allow({
    required GroupId groupId,
    required String inviteId,
    required UserId userId,
    required String proof,
  }) {
    _grants.add((groupId.value, inviteId, userId.value, proof));
  }

  @override
  bool verify({
    required GroupId groupId,
    required String inviteId,
    required UserId userId,
    required String proof,
  }) {
    return _grants.contains((groupId.value, inviteId, userId.value, proof));
  }
}
