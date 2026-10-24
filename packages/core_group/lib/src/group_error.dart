import 'package:core_domain/core_domain.dart';

/// Ошибки проекции группы. Доменные, не исключения.
sealed class GroupError {
  const GroupError();

  @override
  String toString() => runtimeType.toString();
}

class NotInitialized extends GroupError {
  const NotInitialized();
}

class AlreadyInitialized extends GroupError {
  const AlreadyInitialized();
}

class GroupIdMismatch extends GroupError {
  const GroupIdMismatch();
}

class InvalidEvent extends GroupError {
  const InvalidEvent(this.error);

  final GroupEventError error;

  @override
  String toString() => 'InvalidEvent($error)';
}

class NotAMember extends GroupError {
  const NotAMember();
}

class Forbidden extends GroupError {
  const Forbidden();
}

class TargetNotMember extends GroupError {
  const TargetNotMember();
}

class OwnerImmutable extends GroupError {
  const OwnerImmutable();
}

class OwnerRoleNotAssignable extends GroupError {
  const OwnerRoleNotAssignable();
}

class SelfTargetForbidden extends GroupError {
  const SelfTargetForbidden();
}

class UnknownInvite extends GroupError {
  const UnknownInvite();
}

class InviteProofRequired extends GroupError {
  const InviteProofRequired();
}

class InvalidInviteProof extends GroupError {
  const InvalidInviteProof();
}

class InviteExists extends GroupError {
  const InviteExists();
}

class InviteExpired extends GroupError {
  const InviteExpired();
}

class InviteExhausted extends GroupError {
  const InviteExhausted();
}

class JoinNotPending extends GroupError {
  const JoinNotPending();
}

class JoinAlreadyPending extends GroupError {
  const JoinAlreadyPending();
}

class UnknownChannel extends GroupError {
  const UnknownChannel();
}

class ChannelExists extends GroupError {
  const ChannelExists();
}

class InvalidKeyEpoch extends GroupError {
  const InvalidKeyEpoch();
}
