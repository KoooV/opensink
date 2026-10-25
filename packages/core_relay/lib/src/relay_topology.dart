import 'package:core_domain/core_domain.dart';
import 'package:meta/meta.dart';

/// Presence-анонс узла в терминах релейного слоя.
@immutable
class RelayPeer {
  const RelayPeer({
    required this.peerId,
    required this.neighbors,
    required this.updatedAt,
    this.canRelay = false,
    this.capacityBytesPerSecond = 0,
    this.rtt = const Duration(milliseconds: 100),
    this.loadBytesPerSecond = 0,
  });

  final PeerId peerId;

  /// Прямые соседи, заявленные в presence.
  final Set<PeerId> neighbors;

  /// Момент получения анонса.
  final DateTime updatedAt;

  /// Готов ли узел добровольно пересылать чужие кадры.
  final bool canRelay;

  /// Заявленная ёмкость в байтах в секунду.
  final int capacityBytesPerSecond;

  /// Измеренный RTT до узла.
  final Duration rtt;

  /// Наблюдаемая/заявленная текущая нагрузка.
  final int loadBytesPerSecond;

  /// Чем меньше, тем лучше. Нагрузка нормируется на ёмкость.
  double get relayScore {
    if (capacityBytesPerSecond <= 0) {
      return double.infinity;
    }
    final loadRatio = loadBytesPerSecond / capacityBytesPerSecond;
    return rtt.inMilliseconds + loadRatio * 1000;
  }

  bool isFresh(DateTime now, Duration maxAge) =>
      now.difference(updatedAt) <= maxAge;

  RelayPeer copyWith({
    Set<PeerId>? neighbors,
    DateTime? updatedAt,
    bool? canRelay,
    int? capacityBytesPerSecond,
    Duration? rtt,
    int? loadBytesPerSecond,
  }) {
    return RelayPeer(
      peerId: peerId,
      neighbors: neighbors ?? this.neighbors,
      updatedAt: updatedAt ?? this.updatedAt,
      canRelay: canRelay ?? this.canRelay,
      capacityBytesPerSecond:
          capacityBytesPerSecond ?? this.capacityBytesPerSecond,
      rtt: rtt ?? this.rtt,
      loadBytesPerSecond: loadBytesPerSecond ?? this.loadBytesPerSecond,
    );
  }
}

/// Граф достижимости, собранный из presence-анонсов.
///
/// Слой не доверяет анонсам как маршрутам: соседство используется только для
/// выбора одного промежуточного узла. Неизвестные/устаревшие анонсы
/// игнорируются.
class RelayTopology {
  RelayTopology({
    this.maxAge = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration maxAge;
  final DateTime Function() _clock;
  final Map<PeerId, RelayPeer> _peers = <PeerId, RelayPeer>{};
  final Set<PeerId> _localNeighbors = <PeerId>{};
  PeerId? _localPeerId;

  /// Назначает локальный узел, ссылки которого подтверждены транспортом.
  void setLocalPeer(PeerId peerId) {
    if (_localPeerId == peerId) {
      return;
    }
    _localPeerId = peerId;
    _localNeighbors.clear();
  }

  /// Добавляет подтверждённый прямым транспортом линк локального узла.
  ///
  /// Presence получателя может ещё не дойти, но релей обязан знать свои
  /// собственные линки, чтобы переслать кадр следующему хопу.
  void addLocalNeighbor(PeerId peerId) {
    if (_localPeerId == null || peerId == _localPeerId) {
      return;
    }
    _localNeighbors.add(peerId);
  }

  /// Засевает линки, установленные до создания релейного транспорта.
  ///
  /// Вызывается после [setLocalPeer]; до него метод ничего не делает.
  void seedLocalNeighbors(Iterable<PeerId> peerIds) {
    for (final peerId in peerIds) {
      addLocalNeighbor(peerId);
    }
  }

  /// Убирает локальный линк после разрыва или ошибки транспорта.
  void removeLocalNeighbor(PeerId peerId) {
    _localNeighbors.remove(peerId);
  }

  Set<PeerId> get localNeighbors => Set<PeerId>.unmodifiable(_localNeighbors);

  void applyPresence(
    PeerId peerId, {
    required Iterable<PeerId> neighbors,
    bool canRelay = false,
    int capacityBytesPerSecond = 0,
    Duration rtt = const Duration(milliseconds: 100),
    int loadBytesPerSecond = 0,
    DateTime? at,
  }) {
    final now = _clock();
    final receivedAt = at != null && at.isAfter(now) ? now : (at ?? now);
    _apply(
      RelayPeer(
        peerId: peerId,
        neighbors: Set<PeerId>.unmodifiable(neighbors),
        updatedAt: receivedAt,
        canRelay: canRelay,
        capacityBytesPerSecond: capacityBytesPerSecond,
        rtt: rtt,
        loadBytesPerSecond: loadBytesPerSecond,
      ),
    );
  }

  void announce(RelayPeer peer) {
    final now = _clock();
    _apply(
      RelayPeer(
        peerId: peer.peerId,
        neighbors: Set<PeerId>.unmodifiable(peer.neighbors),
        updatedAt: peer.updatedAt.isAfter(now) ? now : peer.updatedAt,
        canRelay: peer.canRelay,
        capacityBytesPerSecond: peer.capacityBytesPerSecond,
        rtt: peer.rtt,
        loadBytesPerSecond: peer.loadBytesPerSecond,
      ),
    );
  }

  /// Применяет только более новый анонс: старый не откатывает маршруты.
  void _apply(RelayPeer peer) {
    final current = _peers[peer.peerId];
    if (current != null && !peer.updatedAt.isAfter(current.updatedAt)) {
      return;
    }
    _peers[peer.peerId] = peer;
  }

  void remove(PeerId peerId) {
    _peers.remove(peerId);
    _localNeighbors.remove(peerId);
  }

  /// Снимает с узла только relay-роль, сохраняя его presence и прямые линки.
  void disableRelay(PeerId peerId) {
    final peer = _peers[peerId];
    if (peer == null || !peer.canRelay) {
      return;
    }
    _peers[peerId] = peer.copyWith(canRelay: false);
  }

  RelayPeer? infoFor(PeerId peerId) => _peers[peerId];

  /// Узлы, для которых есть presence-анонс.
  Set<PeerId> get knownPeerIds => Set<PeerId>.unmodifiable(_peers.keys);

  /// Перекрывает метрики анонса локальными измерениями.
  ///
  /// [RelayPeer.updatedAt] намеренно не меняется: наблюдение не продлевает
  /// жизнь presence-анонса, а лишь уточняет его RTT/нагрузку.
  void observeLink(PeerId peerId, {Duration? rtt, int? loadBytesPerSecond}) {
    final peer = _peers[peerId];
    if (peer == null || (rtt == null && loadBytesPerSecond == null)) {
      return;
    }
    _peers[peerId] = peer.copyWith(
      rtt: rtt,
      loadBytesPerSecond: loadBytesPerSecond,
    );
  }

  Set<PeerId> neighborsOf(PeerId peerId) {
    if (peerId == _localPeerId) {
      return Set<PeerId>.unmodifiable(_localNeighbors);
    }
    return _peers[peerId]?.neighbors ?? const <PeerId>{};
  }

  /// Есть ли линк между двумя узлами (presence или подтверждённый локально).
  bool linked(PeerId a, PeerId b) {
    if (a == b) {
      return false;
    }
    if (_localPeerId == a && _localNeighbors.contains(b)) {
      return true;
    }
    if (_localPeerId == b && _localNeighbors.contains(a)) {
      return true;
    }
    if (_peers[a]?.neighbors.contains(b) ?? false) {
      return true;
    }
    return _peers[b]?.neighbors.contains(a) ?? false;
  }

  /// Кандидаты для пути source → relay → destination.
  List<RelayPeer> candidates({
    required PeerId source,
    required PeerId destination,
    DateTime? now,
  }) {
    final at = now ?? _clock();
    return _peers.values
        .where(
          (peer) =>
              peer.peerId != source &&
              peer.peerId != destination &&
              peer.canRelay &&
              peer.capacityBytesPerSecond > 0 &&
              peer.isFresh(at, maxAge) &&
              peer.neighbors.contains(source) &&
              peer.neighbors.contains(destination),
        )
        .toList(growable: false);
  }

  RelayPeer? selectRelay({
    required PeerId source,
    required PeerId destination,
    Set<PeerId> exclude = const <PeerId>{},
    DateTime? now,
  }) {
    final available = candidates(
      source: source,
      destination: destination,
      now: now,
    ).where((peer) => !exclude.contains(peer.peerId)).toList();
    if (available.isEmpty) {
      return null;
    }
    available.sort((left, right) {
      final byScore = left.relayScore.compareTo(right.relayScore);
      if (byScore != 0) {
        return byScore;
      }
      return left.peerId.toString().compareTo(right.peerId.toString());
    });
    return available.first;
  }

  /// Следующий хоп из [from] к [destination].
  ///
  /// Прямой сосед предпочтительнее; иначе выбирается общий релей.
  PeerId? nextHop({
    required PeerId from,
    required PeerId destination,
    Set<PeerId> exclude = const <PeerId>{},
  }) {
    if (!exclude.contains(destination) && linked(from, destination)) {
      return destination;
    }
    return selectRelay(
      source: from,
      destination: destination,
      exclude: exclude,
    )?.peerId;
  }

  /// Доступен ли маршрут (прямой или через релея).
  bool routes(PeerId from, PeerId destination) =>
      linked(from, destination) ||
      selectRelay(source: from, destination: destination) != null;
}
