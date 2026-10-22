import '../models/identifiers.dart';
import '../result.dart';

/// Все события, влияющие на состояние группы.
/// Состояние группы — чистая функция от множества этих событий.
sealed class GroupEvent {
  const GroupEvent({
    required this.id,
    required this.groupId,
    required this.authorId,
    required this.timestamp,
  });

  final EventId id;
  final GroupId groupId;
  final UserId authorId;
  final int timestamp; // Unix ms

  /// Каноническое представление события для подписи / верификации.
  /// Должно быть детерминированным (одинаковое на всех узлах).
  ///
  /// ⚠ Подпись события носится только на уровне [Envelope] (бинарный
  /// конверт). Доменное событие не подписывается отдельно — доверие
  /// устанавливается подписью конверта, а не полем внутри события.
  Map<String, Object?> toCanonicalMap();

  /// Проверка базовых инвариантов события (не зависит от подписи).
  Result<void, GroupEventError> validateInvariants();
}

class GroupCreated extends GroupEvent {
  const GroupCreated({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,

    required this.name,
    required this.ownerId,
    required this.initialMembers,
  });

  final String name;
  final UserId ownerId;
  final Set<UserId> initialMembers;

  @override
  Map<String, Object?> toCanonicalMap() => {
        'type': 'GroupCreated',
        'id': id.value,
        'groupId': groupId.value,
        'authorId': authorId.value,
        'timestamp': timestamp,
        'name': name,
        'ownerId': ownerId.value,
        'initialMembers': initialMembers.map((e) => e.value).toList()..sort(),
      };

  @override
  Result<void, GroupEventError> validateInvariants() {
    if (name.isEmpty) {
      return Err(emptyName);
    }
    if (initialMembers.isEmpty) {
      return Err(noInitialMembers);
    }
    return Ok(null);
  }
}

class MemberAdded extends GroupEvent {
  const MemberAdded({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,

    required this.userId,
  });

  final UserId userId;

  @override
  Map<String, Object?> toCanonicalMap() => {
        'type': 'MemberAdded',
        'id': id.value,
        'groupId': groupId.value,
        'authorId': authorId.value,
        'timestamp': timestamp,
        'userId': userId.value,
      };

  @override
  Result<void, GroupEventError> validateInvariants() => Ok(null);
}

class MemberRemoved extends GroupEvent {
  const MemberRemoved({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,

    required this.userId,
  });

  final UserId userId;

  @override
  Map<String, Object?> toCanonicalMap() => {
        'type': 'MemberRemoved',
        'id': id.value,
        'groupId': groupId.value,
        'authorId': authorId.value,
        'timestamp': timestamp,
        'userId': userId.value,
      };

  @override
  Result<void, GroupEventError> validateInvariants() => Ok(null);
}

class ChannelCreated extends GroupEvent {
  const ChannelCreated({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,

    required this.channelId,
    required this.name,
    required this.type,
  });

  final ChannelId channelId;
  final String name;
  final String type;

  @override
  Map<String, Object?> toCanonicalMap() => {
        'type': 'ChannelCreated',
        'id': id.value,
        'groupId': groupId.value,
        'authorId': authorId.value,
        'timestamp': timestamp,
        'channelId': channelId.value,
        'name': name,
        'channelType': type,
      };

  @override
  Result<void, GroupEventError> validateInvariants() {
    if (name.isEmpty) {
      return Err(emptyName);
    }
    return Ok(null);
  }
}

class ChannelDeleted extends GroupEvent {
  const ChannelDeleted({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,

    required this.channelId,
  });

  final ChannelId channelId;

  @override
  Map<String, Object?> toCanonicalMap() => {
        'type': 'ChannelDeleted',
        'id': id.value,
        'groupId': groupId.value,
        'authorId': authorId.value,
        'timestamp': timestamp,
        'channelId': channelId.value,
      };

  @override
  Result<void, GroupEventError> validateInvariants() => Ok(null);
}

class GroupRenamed extends GroupEvent {
  const GroupRenamed({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,

    required this.name,
  });

  final String name;

  @override
  Map<String, Object?> toCanonicalMap() => {
        'type': 'GroupRenamed',
        'id': id.value,
        'groupId': groupId.value,
        'authorId': authorId.value,
        'timestamp': timestamp,
        'name': name,
      };

  @override
  Result<void, GroupEventError> validateInvariants() {
    if (name.isEmpty) {
      return Err(emptyName);
    }
    return Ok(null);
  }
}

class OwnerTransferred extends GroupEvent {
  const OwnerTransferred({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,

    required this.newOwnerId,
  });

  final UserId newOwnerId;

  @override
  Map<String, Object?> toCanonicalMap() => {
        'type': 'OwnerTransferred',
        'id': id.value,
        'groupId': groupId.value,
        'authorId': authorId.value,
        'timestamp': timestamp,
        'newOwnerId': newOwnerId.value,
      };

  @override
  Result<void, GroupEventError> validateInvariants() => Ok(null);
}

/// Ошибки валидации групповых событий.
sealed class GroupEventError {
  const GroupEventError();
}

/// Имя группы/канала пустое.
class EmptyName extends GroupEventError {
  const EmptyName();
}

/// При создании группы нет начальных участников.
class NoInitialMembers extends GroupEventError {
  const NoInitialMembers();
}

const GroupEventError emptyName = EmptyName();
const GroupEventError noInitialMembers = NoInitialMembers();
