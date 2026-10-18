/// Транспортный уровень: отправка/приём байт в узле сети (P2P или через релей).
abstract class Transport {
  /// Поток входящих сообщений.
  Stream<TransportMessage> get incoming;

  /// Отправляет сообщение узлу.
  Future<void> send(PeerId to, List<int> data);

  /// Возвращает список известных peer'ов.
  Set<PeerId> get knownPeers;

  Future<void> close();
}

@immutable
class TransportMessage {
  const TransportMessage({
    required this.from,
    required this.payload,
    required this.timestamp,
  });

  final PeerId from;
  final List<int> payload;
  final int timestamp;
}
