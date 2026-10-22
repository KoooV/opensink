import '../../core_domain.dart' show FakeSignalingChannel;
import '../models/identifiers.dart';
import 'package:meta/meta.dart';

import 'fakes.dart' show FakeSignalingChannel;

/// Сообщение сигнализации (WebRTC offer / answer / ICE-кандидат / hangup).
@immutable
class SignalingMessage {
  const SignalingMessage({
    required this.topic,
    required this.bytes,
    required this.from,
    required this.timestamp,
  });

  /// Тема канала сигнализации (topic комнаты).
  final String topic;

  /// Децепированное payload.
  final List<int> bytes;

  /// Отправитель.
  final PeerId from;

  /// Время отправки (Unix ms).
  final int timestamp;

  @override
  String toString() => 'SignalingMessage(topic=$topic, from=$from)';
}

/// Абстракция над любым каналом сигнализации (Nostr, трекер, LAN, QR).
///
/// Реализация скрыта за этим интерфейсом; для тестов — [FakeSignalingChannel].
abstract class SignalingChannel {
  /// Подписывается на входящие сигнальные сообщения по теме.
  Future<void> join(String topic);

  /// Отправляет сигнальное сообщение в тему.
  Future<void> publish(String topic, List<int> bytes);

  /// Поток входящих сигнальных сообщений по joins.
  Stream<SignalingMessage> get incoming;

  /// Закрывает канал.
  Future<void> close();
}
