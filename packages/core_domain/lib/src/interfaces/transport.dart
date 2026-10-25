import '../../core_domain.dart' show FakeTransport;
import '../models/identifiers.dart';
import 'fakes.dart' show FakeTransport;
import 'peer_link.dart';
import 'package:meta/meta.dart';

/// Событие транспортного уровня.
@immutable
class PeerLinkEvent {
  const PeerLinkEvent(this.type, this.peerId, [this.error]);

  final String type; // 'connected' | 'disconnected' | 'error' | 'stats'
  final PeerId? peerId;
  final Object? error;

  @override
  String toString() => 'PeerLinkEvent(type=$type, peerId=$peerId)';
}

/// Входящий relay-кадр с отдельного канала `relay`.
@immutable
class RelayDatagram {
  const RelayDatagram({
    required this.from,
    required this.bytes,
    required this.timestamp,
  });

  final PeerId from;
  final List<int> bytes;
  final int timestamp; // Unix ms

  @override
  String toString() =>
      'RelayDatagram(from=$from, bytes=${bytes.length})';
}

/// Класс-маркер: relay-трафик не смешивается с обычным control-payload.
typedef RelayIncoming = RelayDatagram;

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

  /// Отправляет relay-кадр только в отдельный канал `relay`.
  Future<void> sendRelay(PeerId dst, List<int> bytes);

  /// Входящие relay-кадры из канала `relay`.
  Stream<RelayDatagram> get relayIncoming;

  /// Закрывает транспорт и все соединения.
  Future<void> close();
}
