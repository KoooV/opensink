/// Топология медиа-звонка: SFU / mesh / relay.
abstract class MediaTopology {
  /// Присоединиться к голосовому каналу.
  Future<void> join(ChannelId channelId);

  /// Покинуть канал.
  Future<void> leave();

  /// Отправить локальный трек (аудио/видео/экран).
  Future<void> addTrack(String trackId, MediaTrackKind kind);

  /// Удалить трек.
  Future<void> removeTrack(String trackId);

  Stream<MediaEvent> get events;
}

enum MediaTrackKind { audio, video, screen }

sealed class MediaEvent {
  const MediaEvent();
  class PeerJoined extends MediaEvent {
    const PeerJoined(this.peerId);
    final PeerId peerId;
  }
  class PeerLeft extends MediaEvent {
    const PeerLeft(this.peerId);
    final PeerId peerId;
  }
  class TrackAdded extends MediaEvent {
    const TrackAdded(this.peerId, this.trackId, this.kind);
    final PeerId peerId;
    final String trackId;
    final MediaTrackKind kind;
  }
  class TrackRemoved extends MediaEvent {
    const TrackRemoved(this.peerId, this.trackId);
    final PeerId peerId;
    final String trackId;
  }
}
