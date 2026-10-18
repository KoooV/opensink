import '../models/identifiers.dart';

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
}

/// Абстракция над состоянием группы (чтение и подписка на изменения).
abstract class IGroupState {
  /// Текущее состояние группы.
  GroupState get state;

  /// Поток изменений состояния группы.
  Stream<GroupState> watch();
}
