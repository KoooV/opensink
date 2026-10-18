/// Релей: маршрутизация сообщений через доверенных участников группы.
abstract class Relay {
  /// Отправляет сообщение членам группы, возможно через промежуточных релеев.
  Future<void> relayToGroup(GroupId groupId, List<int> payload);

  /// Подписывается на входящие релейные сообщения.
  Stream<RelayMessage> get incoming;

  Future<void> close();
}

@immutable
class RelayMessage {
  const RelayMessage({
    required this.from,
    required this.groupId,
    required this.payload,
    required this.timestamp,
  });

  final PeerId from;
  final GroupId groupId;
  final List<int> payload;
  final int timestamp;
}
