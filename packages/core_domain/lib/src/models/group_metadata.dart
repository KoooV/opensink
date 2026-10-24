import 'package:meta/meta.dart';

import '../result.dart';
import 'identifiers.dart';

/// Источник доверия для группы.
enum GroupOrigin {
  /// Группа создана локально; genesis ещё может быть не записан.
  created('created'),

  /// Группа открыта по инвайту; genesis известен из ссылки.
  invited('invited');

  const GroupOrigin(this.value);

  final String value;

  static GroupOrigin? fromValue(String value) {
    for (final origin in values) {
      if (origin.value == value) return origin;
    }
    return null;
  }
}

/// Доменные ошибки метаданных группы.
sealed class GroupMetadataError {
  const GroupMetadataError();

  @override
  String toString() => runtimeType.toString();
}

/// Сохранённые метаданные повреждены или несовместимы.
class CorruptedGroupMetadata extends GroupMetadataError {
  const CorruptedGroupMetadata(this.reason);

  final String reason;

  @override
  String toString() => 'CorruptedGroupMetadata($reason)';
}

/// Инфраструктурная ошибка хранилища метаданных.
class GroupMetadataStorageFailure extends GroupMetadataError {
  const GroupMetadataStorageFailure(this.reason);

  final String reason;

  @override
  String toString() => 'GroupMetadataStorageFailure($reason)';
}

/// Доверенный корень группы.
///
/// [groupId] и [genesisEventId] не выбираются из лога: create сохраняет
/// сгенерированный id до genesis, invite приносит оба значения из ссылки.
/// Для `created` до записи genesis [genesisEventId] равен `null`.
@immutable
class GroupMetadata {
  const GroupMetadata({
    required this.groupId,
    required this.origin,
    required this.createdAt,
    this.genesisEventId,
  });

  final GroupId groupId;
  final EventId? genesisEventId;
  final GroupOrigin origin;
  final int createdAt;

  bool get isReady => genesisEventId != null;

  GroupMetadata withGenesis(EventId genesis) {
    return GroupMetadata(
      groupId: groupId,
      genesisEventId: genesis,
      origin: origin,
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'group_id': groupId.value,
    if (genesisEventId != null) 'genesis_event_id': genesisEventId!.value,
    'origin': origin.value,
    'created_at': createdAt,
  };

  static Result<GroupMetadata, GroupMetadataError> fromJson(Object? json) {
    if (json is! Map) {
      return const Err(CorruptedGroupMetadata('metadata is not an object'));
    }
    final version = json['version'];
    if (version != 1) {
      return const Err(CorruptedGroupMetadata('unsupported version'));
    }
    final groupId = json['group_id'];
    if (groupId is! String || groupId.isEmpty) {
      return const Err(CorruptedGroupMetadata('missing group_id'));
    }
    final originValue = json['origin'];
    if (originValue is! String) {
      return const Err(CorruptedGroupMetadata('missing origin'));
    }
    final origin = GroupOrigin.fromValue(originValue);
    if (origin == null) {
      return const Err(CorruptedGroupMetadata('unknown origin'));
    }
    final createdAt = json['created_at'];
    if (createdAt is! int) {
      return const Err(CorruptedGroupMetadata('invalid created_at'));
    }
    final genesis = json['genesis_event_id'];
    if (genesis != null && (genesis is! String || genesis.isEmpty)) {
      return const Err(CorruptedGroupMetadata('invalid genesis_event_id'));
    }
    if (origin == GroupOrigin.invited && genesis == null) {
      return const Err(CorruptedGroupMetadata('invited group without genesis'));
    }
    return Ok(
      GroupMetadata(
        groupId: GroupId(groupId),
        genesisEventId: genesis == null ? null : EventId(genesis as String),
        origin: origin,
        createdAt: createdAt,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupMetadata &&
          runtimeType == other.runtimeType &&
          groupId == other.groupId &&
          genesisEventId == other.genesisEventId &&
          origin == other.origin &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(groupId, genesisEventId, origin, createdAt);

  @override
  String toString() =>
      'GroupMetadata(groupId=${groupId.value}, '
      'genesisEventId=${genesisEventId?.value}, origin=${origin.value})';
}
