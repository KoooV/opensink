import 'identifiers.dart';
import 'user.dart';

/// Текстовый или голосовой канал внутри группы.
class Channel {
  const Channel({
    required this.id,
    required this.groupId,
    required this.name,
    required this.type, // 'text' | 'voice'
    required this.createdBy,
    required this.createdAt,
  });

  final ChannelId id;
  final GroupId groupId;
  final String name;
  final String type;
  final UserId createdBy;
  final int createdAt;

  Channel copyWith({
    ChannelId? id,
    GroupId? groupId,
    String? name,
    String? type,
    UserId? createdBy,
    int? createdAt,
  }) {
    return Channel(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      name: name ?? this.name,
      type: type ?? this.type,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Channel && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Channel(id=$id, name=$name, type=$type)';
}
