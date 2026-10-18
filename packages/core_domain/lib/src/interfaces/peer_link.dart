/// Абстракция над WebRTC peer connection.
/// Реализация в core_peer (flutter_webrtc); платформенные детали — за интерфейсом.
abstract class PeerLink {
  /// Id удалённого peer.
  PeerId get remotePeerId;

  /// Поток входящих данных (текст / бинарные чанки мультимедиа).
  Stream<List<int>> get incomingData;

  /// Поток изменений состояния соединения.
  Stream<ConnectionState> get state;

  /// Отправляет бинарные данные peer'у.
  Future<void> sendData(List<int> data);

  /// Устанавливает удалённое SDP описание (offer / answer).
  Future<void> setRemoteDescription(String sdp, String type);

  /// Создаёт локальный offer.
  Future<String> createOffer();

  /// Создаёт локальный answer.
  Future<String> createAnswer();

  /// Добавляет ICE-кандидата.
  Future<void> addIceCandidate(String candidate, String sdpMid, int sdpMLineIndex);

  /// Закрывает соединение.
  Future<void> close();
}

enum ConnectionState {
  new_,
  connecting,
  connected,
  disconnected,
  failed,
  closed,
}
