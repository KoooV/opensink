import '../models/group_role.dart';
import '../models/identifiers.dart';
import '../result.dart';

/// Режим инвайт-ссылки.
enum InviteMode { open, approval }

/// Домен доказательства владения секретом инвайта.
const String inviteProofDomain = 'opensink/group/invite-proof/v1|';

/// Каноническое сообщение, по которому считается HMAC инвайта.
String inviteProofMessage({
  required GroupId groupId,
  required String inviteId,
  required UserId userId,
}) => '$inviteProofDomain${groupId.value}|$inviteId|${userId.value}';

/// Все события, влияющие на состояние группы.
/// Состояние группы — чистая функция от множества этих событий.
sealed class GroupEvent {
  const GroupEvent({
    required this.id,
    required this.groupId,
    required this.authorId,
    required this.timestamp,
    this.counter = 0,
    this.prevId,
  });

  final EventId id;
  final GroupId groupId;
  final UserId authorId;
  final int timestamp; // Unix ms

  /// Логический счётчик HLC. Вместе с [timestamp] и [id] задаёт
  /// детерминированный порядок разрешения конфликтов.
  final int counter;

  /// Предыдущее событие **того же автора** в группе. Образует проверяемую
  /// цепочку и запрещает бэкдейтинг/форк в логе автора.
  final EventId? prevId;

  /// Каноническое представление события для подписи / верификации.
  /// Должно быть детерминированным (одинаковое на всех узлах).
  ///
  /// ⚠ Подпись события носится только на уровне `Envelope` (бинарный
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
    super.counter = 0,
    super.prevId,

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
    'counter': counter,
    'prevId': prevId?.value,
    'name': name,
    'ownerId': ownerId.value,
    'initialMembers': initialMembers.map((e) => e.value).toList()..sort(),
  };

  @override
  Result<void, GroupEventError> validateInvariants() {
    if (prevId != null) {
      return const Err(rootEventHasPrev);
    }
    if (name.isEmpty) {
      return const Err(emptyName);
    }
    if (initialMembers.isEmpty) {
      return const Err(noInitialMembers);
    }
    return const Ok(null);
  }
}

class MemberAdded extends GroupEvent {
  const MemberAdded({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,
    super.counter = 0,
    super.prevId,

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
    'counter': counter,
    'prevId': prevId?.value,
    'userId': userId.value,
  };

  @override
  Result<void, GroupEventError> validateInvariants() => const Ok(null);
}

class MemberRemoved extends GroupEvent {
  const MemberRemoved({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,
    super.counter = 0,
    super.prevId,

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
    'counter': counter,
    'prevId': prevId?.value,
    'userId': userId.value,
  };

  @override
  Result<void, GroupEventError> validateInvariants() => const Ok(null);
}

class ChannelCreated extends GroupEvent {
  const ChannelCreated({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,
    super.counter = 0,
    super.prevId,

    required this.channelId,
    required this.name,
    required this.type,
    this.minViewRole = GroupRole.member,
    this.minPostRole = GroupRole.member,
  });

  final ChannelId channelId;
  final String name;
  final String type;
  final GroupRole minViewRole;
  final GroupRole minPostRole;

  @override
  Map<String, Object?> toCanonicalMap() => {
    'type': 'ChannelCreated',
    'id': id.value,
    'groupId': groupId.value,
    'authorId': authorId.value,
    'timestamp': timestamp,
    'counter': counter,
    'prevId': prevId?.value,
    'channelId': channelId.value,
    'name': name,
    'channelType': type,
    'minViewRole': minViewRole.name,
    'minPostRole': minPostRole.name,
  };

  @override
  Result<void, GroupEventError> validateInvariants() {
    if (name.isEmpty) {
      return const Err(emptyName);
    }
    return const Ok(null);
  }
}

class ChannelDeleted extends GroupEvent {
  const ChannelDeleted({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,
    super.counter = 0,
    super.prevId,

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
    'counter': counter,
    'prevId': prevId?.value,
    'channelId': channelId.value,
  };

  @override
  Result<void, GroupEventError> validateInvariants() => const Ok(null);
}

class GroupRenamed extends GroupEvent {
  const GroupRenamed({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,
    super.counter = 0,
    super.prevId,

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
    'counter': counter,
    'prevId': prevId?.value,
    'name': name,
  };

  @override
  Result<void, GroupEventError> validateInvariants() {
    if (name.isEmpty) {
      return const Err(emptyName);
    }
    return const Ok(null);
  }
}

class OwnerTransferred extends GroupEvent {
  const OwnerTransferred({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,
    super.counter = 0,
    super.prevId,

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
    'counter': counter,
    'prevId': prevId?.value,
    'newOwnerId': newOwnerId.value,
  };

  @override
  Result<void, GroupEventError> validateInvariants() => const Ok(null);
}

/// Выдача инвайт-ссылки. Секрет ссылки в событии не хранится.
class InviteIssued extends GroupEvent {
  const InviteIssued({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,
    super.counter = 0,
    super.prevId,

    required this.inviteId,
    required this.mode,
    this.maxUses,
    this.expiresAt,
    this.relayHint = '',
  });

  final String inviteId;
  final InviteMode mode;
  final int? maxUses;
  final int? expiresAt;
  final String relayHint;

  @override
  Map<String, Object?> toCanonicalMap() => {
    'type': 'InviteIssued',
    'id': id.value,
    'groupId': groupId.value,
    'authorId': authorId.value,
    'timestamp': timestamp,
    'counter': counter,
    'prevId': prevId?.value,
    'inviteId': inviteId,
    'inviteMode': mode.name,
    'maxUses': maxUses,
    'expiresAt': expiresAt,
    'relayHint': relayHint,
  };

  @override
  Result<void, GroupEventError> validateInvariants() {
    if (inviteId.isEmpty) {
      return const Err(emptyInviteIdentifier);
    }
    if (maxUses != null && maxUses! <= 0) {
      return const Err(invalidInviteUses);
    }
    if (expiresAt != null && expiresAt! <= timestamp) {
      return const Err(invalidInviteExpiry);
    }
    if (mode == InviteMode.open && maxUses == null && expiresAt == null) {
      return const Err(unboundedOpenInvite);
    }
    return const Ok(null);
  }
}

/// Вход по инвайту. Автор события — сам входящий.
class MemberJoined extends GroupEvent {
  const MemberJoined({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,
    super.counter = 0,
    super.prevId,

    required this.inviteId,
    this.inviteProof = '',
  });

  final String inviteId;

  /// HMAC секрета инвайта над [inviteProofMessage]; доказывает владение
  /// `group_secret`, а не только знание публичного `inviteId`.
  final String inviteProof;

  @override
  Map<String, Object?> toCanonicalMap() => {
    'type': 'MemberJoined',
    'id': id.value,
    'groupId': groupId.value,
    'authorId': authorId.value,
    'timestamp': timestamp,
    'counter': counter,
    'prevId': prevId?.value,
    'inviteId': inviteId,
    'inviteProof': inviteProof,
  };

  @override
  Result<void, GroupEventError> validateInvariants() {
    if (inviteId.isEmpty) {
      return const Err(emptyInviteIdentifier);
    }
    return const Ok(null);
  }
}

/// Подтверждение входа админом/владельцем.
class MemberApproved extends GroupEvent {
  const MemberApproved({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,
    super.counter = 0,
    super.prevId,

    required this.userId,
    required this.inviteId,
  });

  final UserId userId;
  final String inviteId;

  @override
  Map<String, Object?> toCanonicalMap() => {
    'type': 'MemberApproved',
    'id': id.value,
    'groupId': groupId.value,
    'authorId': authorId.value,
    'timestamp': timestamp,
    'counter': counter,
    'prevId': prevId?.value,
    'userId': userId.value,
    'inviteId': inviteId,
  };

  @override
  Result<void, GroupEventError> validateInvariants() {
    if (inviteId.isEmpty) {
      return const Err(emptyInviteIdentifier);
    }
    return const Ok(null);
  }
}

/// Назначение роли. Роль owner назначается только через передачу владения.
class RoleSet extends GroupEvent {
  const RoleSet({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,
    super.counter = 0,
    super.prevId,

    required this.userId,
    required this.role,
  });

  final UserId userId;
  final GroupRole role;

  @override
  Map<String, Object?> toCanonicalMap() => {
    'type': 'RoleSet',
    'id': id.value,
    'groupId': groupId.value,
    'authorId': authorId.value,
    'timestamp': timestamp,
    'counter': counter,
    'prevId': prevId?.value,
    'userId': userId.value,
    'role': role.name,
  };

  @override
  Result<void, GroupEventError> validateInvariants() {
    if (role == GroupRole.owner) {
      return const Err(ownerRoleForbidden);
    }
    return const Ok(null);
  }
}

/// Ручная ротация sender keys. Эпоха может только возрастать.
class KeyRotated extends GroupEvent {
  const KeyRotated({
    required super.id,
    required super.groupId,
    required super.authorId,
    required super.timestamp,
    super.counter = 0,
    super.prevId,

    required this.newEpoch,
  });

  final int newEpoch;

  @override
  Map<String, Object?> toCanonicalMap() => {
    'type': 'KeyRotated',
    'id': id.value,
    'groupId': groupId.value,
    'authorId': authorId.value,
    'timestamp': timestamp,
    'counter': counter,
    'prevId': prevId?.value,
    'newEpoch': newEpoch,
  };

  @override
  Result<void, GroupEventError> validateInvariants() {
    if (newEpoch <= 0) {
      return const Err(invalidKeyEpochValue);
    }
    return const Ok(null);
  }
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

/// Идентификатор инвайта пустой.
class EmptyInviteIdentifier extends GroupEventError {
  const EmptyInviteIdentifier();
}

/// Корневое событие создания группы не может ссылаться на предыдущее.
class RootEventHasPrev extends GroupEventError {
  const RootEventHasPrev();
}

/// Лимит использований инвайта не положительный.
class InvalidInviteUses extends GroupEventError {
  const InvalidInviteUses();
}

/// Срок инвайта не позже момента выдачи.
class InvalidInviteExpiry extends GroupEventError {
  const InvalidInviteExpiry();
}

/// Роль owner нельзя назначить обычным RoleSet.
class OwnerRoleForbidden extends GroupEventError {
  const OwnerRoleForbidden();
}

/// Некорректное значение эпохи ключей.
class InvalidKeyEpochValue extends GroupEventError {
  const InvalidKeyEpochValue();
}

/// Открытый инвайт без лимита использований и срока.
class UnboundedOpenInvite extends GroupEventError {
  const UnboundedOpenInvite();
}

const GroupEventError emptyName = EmptyName();
const GroupEventError noInitialMembers = NoInitialMembers();
const GroupEventError emptyInviteIdentifier = EmptyInviteIdentifier();
const GroupEventError rootEventHasPrev = RootEventHasPrev();
const GroupEventError invalidInviteUses = InvalidInviteUses();
const GroupEventError invalidInviteExpiry = InvalidInviteExpiry();
const GroupEventError ownerRoleForbidden = OwnerRoleForbidden();
const GroupEventError invalidKeyEpochValue = InvalidKeyEpochValue();
const GroupEventError unboundedOpenInvite = UnboundedOpenInvite();
