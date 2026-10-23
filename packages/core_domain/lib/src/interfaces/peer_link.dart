import '../../core_domain.dart' show FakePeerLink;
import '../models/identifiers.dart';

import 'package:meta/meta.dart';

import 'fakes.dart' show FakePeerLink;

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
    this.outgoingBitrate = 0,
  });

  /// Round-trip time.
  final Duration rtt;
  final int bytesSent;
  final int bytesReceived;

  /// Доля потерянных пакетов (0.0–1.0).
  ///
  /// Для SCTP data-channel WebRTC не предоставляет счётчик потерь, поэтому
  /// значение равно 0. Ненулевые значения возможны только при наличии
  /// RTP-медиа (`inbound-rtp`/`remote-inbound-rtp`).
  final double loss;

  /// Исходящий битрейт в битах в секунду (оценка по дельте байт).
  final int outgoingBitrate;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerLinkStats &&
          rtt == other.rtt &&
          bytesSent == other.bytesSent &&
          bytesReceived == other.bytesReceived &&
          loss == other.loss &&
          outgoingBitrate == other.outgoingBitrate;

  @override
  int get hashCode =>
      Object.hash(rtt, bytesSent, bytesReceived, loss, outgoingBitrate);
}

enum PeerLinkState { connecting, connected, closed, failed }

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
