// Базовый тип для всех сущностных идентификаторов.
// Идентификатор — это неопределенная строка, гарантирующая уникальность в рамках типа сущности.
abstract class EntityId {
  const EntityId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EntityId && runtimeType == other.runtimeType && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$runtimeType($value)';
}

class UserId extends EntityId {
  const UserId(super.value);
}

class GroupId extends EntityId {
  const GroupId(super.value);
}

class ChannelId extends EntityId {
  const ChannelId(super.value);
}

class MessageId extends EntityId {
  const MessageId(super.value);
}

class EventId extends EntityId {
  const EventId(super.value);
}

class PeerId extends EntityId {
  const PeerId(super.value);
}
