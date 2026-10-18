import '../models/identifiers.dart';

/// Входящие данные по peer-ссылке.
@immutable
class Incoming {
  const Incoming({
    required this.channel,
    required this.bytes,
    required this.timestamp,
  });

  final String channel;
  final List<int> bytes;
  final int timestamp; // Unix ms
}

/// Статистика peer-ссылки.
@immutable
class PeerLinkStats {
  const PeerLinkStats({
    required this.rtt,
    required this.bytesSent,
    required this.bytesReceived,
    required this.loss,
  });

  /// Round-trip time.
  final Duration rtt;
  final int bytesSent;
  final int bytesReceived;
  /// Доля потерянных пакетов (0.0–1.0).
  final double loss;
}

enum PeerLinkState {
  connecting,
  connected,
  closed,
  failed,
}

/// Абстракция над WebRTC peer connection.
///
/// Реализация в core_peer (flutter_webrtc); платформенные детали — за
/// интерфейсом. Для тестов — [FakePeerLink].
abstract class PeerLink {
  /// Id удалённого peer.
  PeerId get remotePeerId;

  /// Текущее состояние соединения.
  PeerLinkState get state;

  /// Поток изменений состояния.
  Stream<PeerLinkState> get stateStream;

  /// Поток входящих данных.
  Stream<Incoming> get incoming;

  /// Статистика соединения (RTT, байты, потери).
  PeerLinkStats get stats;

  /// Отправляет байты в канал.
  Future<void> send(String channel, List<int> bytes);

  /// Закрывает соединение.
  Future<void> close();
}
