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
    required this.createdAt,
    required this.updatedAt,
  });

  final GroupId id;
  final String name;
  final UserId ownerId;
  final Set<UserId> memberIds;
  final Set<ChannelId> channelIds;
  final int createdAt; // Unix ms
  final int updatedAt; // Unix ms

  GroupState copyWith({
    GroupId? id,
    String? name,
    UserId? ownerId,
    Set<UserId>? memberIds,
    Set<ChannelId>? channelIds,
    int? createdAt,
    int? updatedAt,
  }) {
    return GroupState(
      id: id ?? this.id,
      name: name ?? this.name,
      ownerId: ownerId ?? this.ownerId,
      memberIds: memberIds ?? this.memberIds,
      channelIds: channelIds ?? this.channelIds,
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
