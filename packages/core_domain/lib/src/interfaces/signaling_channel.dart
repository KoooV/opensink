import 'package:meta/meta.dart';

/// Абстракция над любым каналом сигнализации (Nostr, трекер, LAN, QR).
/// Реализация скрыта за этим интерфейсом; для тестов — [FakeSignalingChannel].
abstract class SignalingChannel {
  /// Подписывается на входящие сигнальные сообщения от удалённого peer.
  Stream<SignalingMessage> get incoming;

  /// Отправляет сигнальное сообщение указанному peer.
  Future<void> send(PeerId to, SignalingMessage message);

  /// Закрывает канал.
  Future<void> close();
}

@immutable
class SignalingMessage {
  const SignalingMessage({
    required this.type, // 'offer' | 'answer' | 'ice-candidate' | 'hangup'
    required this.payload,
    required this.timestamp,
  });

  final String type;
  final Map<String, Object?> payload;
  final int timestamp;

  @override
  String toString() => 'SignalingMessage(type=$type, timestamp=$timestamp)';
}
