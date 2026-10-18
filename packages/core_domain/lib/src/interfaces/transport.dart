import '../models/identifiers.dart';
import 'peer_link.dart';

/// Событие транспортного уровня.
@immutable
class PeerLinkEvent {
  const PeerLinkEvent._(this.type, this.peerId, [this.error]);

  final String type; // 'connected' | 'disconnected' | 'error' | 'stats'
  final PeerId? peerId;
  final Object? error;

  @override
  String toString() => 'PeerLinkEvent(type=$type, peerId=$peerId)';
}

/// Транспортный уровень: отправка/приём байт в узле сети (P2P или через релей).
///
/// [Transport] прозрачно выбирает прямой путь или Relay. Реализация скрыта
/// за интерфейсом; для тестов — [FakeTransport].
abstract class Transport {
  /// Устанавливает соединение с peer и возвращает [PeerLink].
  Future<PeerLink> connect(PeerId peerId);

  /// Поток событий транспортного уровня.
  Stream<PeerLinkEvent> get events;

  /// Отправляет байты узлу (прозрачно через прямую ссылку или Relay).
  Future<void> send(PeerId dst, List<int> bytes);

  /// Закрывает транспорт и все соединения.
  Future<void> close();
}
