/// Типизированные ошибки слоя синхронизации.
sealed class SyncError implements Exception {
  const SyncError();
}

class FrameTooLarge extends SyncError {
  const FrameTooLarge(this.size, this.limit);
  final int size;
  final int limit;

  @override
  String toString() => 'FrameTooLarge(size=$size, limit=$limit)';
}

class MalformedFrame extends SyncError {
  const MalformedFrame(this.reason);
  final String reason;

  @override
  String toString() => 'MalformedFrame($reason)';
}

class UnsupportedFrame extends SyncError {
  const UnsupportedFrame(this.type);
  final int type;

  @override
  String toString() => 'UnsupportedFrame($type)';
}

class EventTooLarge extends SyncError {
  const EventTooLarge(this.size, this.limit);
  final int size;
  final int limit;

  @override
  String toString() => 'EventTooLarge(size=$size, limit=$limit)';
}

class MalformedEvent extends SyncError {
  const MalformedEvent(this.reason);
  final String reason;

  @override
  String toString() => 'MalformedEvent($reason)';
}

class EventIdMismatch extends SyncError {
  const EventIdMismatch(this.claimed, this.computed);
  final String claimed;
  final String computed;

  @override
  String toString() => 'EventIdMismatch(claimed=$claimed)';
}

class HlcTooFarInFuture extends SyncError {
  const HlcTooFarInFuture(this.eventHlc, this.nowMs, this.limitMs);

  final int eventHlc;
  final int nowMs;
  final int limitMs;

  @override
  String toString() =>
      'HlcTooFarInFuture(eventHlc=$eventHlc, nowMs=$nowMs, limit=$limitMs)';
}

class InvalidEventAuthor extends SyncError {
  const InvalidEventAuthor();

  @override
  String toString() => 'InvalidEventAuthor';
}

class InvalidPrev extends SyncError {
  const InvalidPrev(this.prevId, this.reason);
  final String prevId;
  final String reason;

  @override
  String toString() => 'InvalidPrev(prev=$prevId, reason=$reason)';
}

class InvalidSignature extends SyncError {
  const InvalidSignature();

  @override
  String toString() => 'InvalidSignature';
}

class NotAMember extends SyncError {
  const NotAMember(this.authorId, this.groupId);
  final String authorId;
  final String groupId;

  @override
  String toString() => 'NotAMember(author=$authorId, group=$groupId)';
}

/// Событие `groupCreated`, не совпадающее с доверенным корнем группы.
class ForeignGroupRoot extends SyncError {
  const ForeignGroupRoot(this.expected, this.claimed);
  final String expected;
  final String claimed;

  @override
  String toString() => 'ForeignGroupRoot(expected=$expected, claimed=$claimed)';
}

/// Незакреплённая группа превысила лимит событий и ждёт `pinGroupRoot`.
class UnpinnedGroupQuarantine extends SyncError {
  const UnpinnedGroupQuarantine(this.groupId, this.limit);
  final String groupId;
  final int limit;

  @override
  String toString() => 'UnpinnedGroupQuarantine(group=$groupId, limit=$limit)';
}

class StorageWriteFailure extends SyncError {
  const StorageWriteFailure(this.reason);
  final String reason;

  @override
  String toString() => 'StorageWriteFailure($reason)';
}

class LocalEventRejected extends SyncError {
  const LocalEventRejected(this.cause);
  final SyncError cause;

  @override
  String toString() => 'LocalEventRejected($cause)';
}

/// Автор превысил ingress-лимит событий за окно.
class AuthorRateLimited extends SyncError {
  const AuthorRateLimited(this.authorId, this.limit, this.windowMs);
  final String authorId;
  final int limit;
  final int windowMs;

  @override
  String toString() => 'AuthorRateLimited(limit=$limit, windowMs=$windowMs)';
}
