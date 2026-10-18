import 'entity_id.dart';
import 'user.dart';
import '../events/group_event.dart';

/// Группа — верхняя сущность доступа.
/// Состояние группы — чистая функция от множества подписанных событий [GroupEvent].
class Group {
  const Group({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.memberIds,
    required this.channelIds,
    required this.eventIds,
    required this.createdAt,
    required this.updatedAt,
  });

  final GroupId id;
  final String name;
  final UserId ownerId;
  final Set<UserId> memberIds;
  final Set<ChannelId> channelIds;
  final Set<EventId> eventIds; // применённые события (дедупликация / replay protection)
  final int createdAt; // Unix ms
  final int updatedAt; // Unix ms

  Group copyWith({
    GroupId? id,
    String? name,
    UserId? ownerId,
    Set<UserId>? memberIds,
    Set<ChannelId>? channelIds,
    Set<EventId>? eventIds,
    int? createdAt,
    int? updatedAt,
  }) {
    return Group(
      id: id ?? this.id,
      name: name ?? this.name,
      ownerId: ownerId ?? this.ownerId,
      memberIds: memberIds ?? this.memberIds,
      channelIds: channelIds ?? this.channelIds,
      eventIds: eventIds ?? this.eventIds,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Применяет подписанное событие к текущему состоянию.
  /// Возвращает новое состояние [Group]. Чистая функция: не мутирует this.
  Group apply(GroupEvent event) {
    switch (event) {
      case GroupCreated e:
        return _applyCreated(e);
      case MemberAdded e:
        return _applyMemberAdded(e);
      case MemberRemoved e:
        return _applyMemberRemoved(e);
      case ChannelCreated e:
        return _applyChannelCreated(e);
      case ChannelDeleted e:
        return _applyChannelDeleted(e);
      case GroupRenamed e:
        return _applyRenamed(e);
      case OwnerTransferred e:
        return _applyOwnerTransferred(e);
    }
  }

  Group _applyCreated(GroupCreated e) => copyWith(
        name: e.name,
        ownerId: e.ownerId,
        memberIds: {...e.initialMembers, e.ownerId},
        createdAt: e.timestamp,
        updatedAt: e.timestamp,
      );

  Group _applyMemberAdded(MemberAdded e) =>
      copyWith(memberIds: {...memberIds, e.userId}, updatedAt: e.timestamp);

  Group _applyMemberRemoved(MemberRemoved e) =>
      copyWith(memberIds: {...memberIds}..remove(e.userId), updatedAt: e.timestamp);

  Group _applyChannelCreated(ChannelCreated e) =>
      copyWith(channelIds: {...channelIds, e.channelId}, updatedAt: e.timestamp);

  Group _applyChannelDeleted(ChannelDeleted e) =>
      copyWith(channelIds: {...channelIds}..remove(e.channelId), updatedAt: e.timestamp);

  Group _applyRenamed(GroupRenamed e) =>
      copyWith(name: e.name, updatedAt: e.timestamp);

  Group _applyOwnerTransferred(OwnerTransferred e) =>
      copyWith(ownerId: e.newOwnerId, updatedAt: e.timestamp);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Group && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Group(id=$id, name=$name, members=${memberIds.length})';
}
