import '../models/group_role.dart';
import '../models/identifiers.dart';

import 'package:meta/meta.dart';

/// Состояние группы — чистая функция от множества подписанных событий.
@immutable
class GroupState {
  const GroupState({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.memberIds,
    required this.channelIds,
    this.pendingJoins = const <UserId, String>{},
    this.memberRoles = const <UserId, GroupRole>{},
    required this.createdAt,
    required this.updatedAt,
  });

  final GroupId id;
  final String name;
  final UserId ownerId;
  final Set<UserId> memberIds;
  final Set<ChannelId> channelIds;

  /// Заявки на вход в режиме approval: пользователь → inviteId.
  final Map<UserId, String> pendingJoins;

  /// Роли участников; пустая карта, если источник их не отдаёт.
  final Map<UserId, GroupRole> memberRoles;
  final int createdAt; // Unix ms
  final int updatedAt; // Unix ms

  GroupState copyWith({
    GroupId? id,
    String? name,
    UserId? ownerId,
    Set<UserId>? memberIds,
    Set<ChannelId>? channelIds,
    Map<UserId, String>? pendingJoins,
    Map<UserId, GroupRole>? memberRoles,
    int? createdAt,
    int? updatedAt,
  }) {
    return GroupState(
      id: id ?? this.id,
      name: name ?? this.name,
      ownerId: ownerId ?? this.ownerId,
      memberIds: memberIds ?? this.memberIds,
      channelIds: channelIds ?? this.channelIds,
      pendingJoins: pendingJoins ?? this.pendingJoins,
      memberRoles: memberRoles ?? this.memberRoles,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Абстракция над состоянием группы (чтение и подписка на изменения).
abstract class IGroupState {
  /// Текущее состояние группы.
  GroupState get state;

  /// Поток изменений состояния группы.
  Stream<GroupState> watch();
}
