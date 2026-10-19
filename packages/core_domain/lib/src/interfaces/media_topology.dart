import '../models/identifiers.dart';
import 'package:meta/meta.dart';

/// Возможности участника медиасессии (кодеки, аппаратное ускорение и т.п.).
@immutable
class PeerCapabilities {
  const PeerCapabilities({
    this.audio = true,
    this.video = true,
    this.screen = false,
    this.maxBitrateKbps,
  });

  final bool audio;
  final bool video;
  final bool screen;
  final int? maxBitrateKbps;
}

/// Тип топологии медиасессии.
enum TopologyType {
  mesh,
  hosted,
}

/// План топологии медиасессии.
@immutable
class TopologyPlan {
  const TopologyPlan({
    required this.type,
    this.host,
    required this.participants,
  });

  final TopologyType type;
  /// Для [TopologyType.hosted] — peer, который хостит сессию (SFU).
  final PeerId? host;
  final Set<PeerId> participants;
}

/// Топология медиа-звонка: mesh или hosted-by-peer.
///
/// Реализация в core_media; для тестов — [FakeMediaTopology].
abstract class MediaTopology {
  /// Вычисляет план топологии для участников и их возможностей.
  TopologyPlan plan(Set<PeerId> participants, Map<PeerId, PeerCapabilities> capabilities);

  /// Закрывает топологию.
  Future<void> close();
}
