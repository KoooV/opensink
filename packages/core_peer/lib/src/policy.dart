import 'package:core_domain/core_domain.dart';
import 'package:meta/meta.dart';

/// Приоритеты для вытеснения при достижении лимита линков.
///
/// Чем больше значение, тем важнее peer. [isProtected] запрещает вытеснение
/// (например, участник активного голосового канала).
abstract interface class PeerPriorityPolicy {
  int priorityOf(PeerId peerId);

  bool isProtected(PeerId peerId);
}

/// Политика по умолчанию: все равны, никто не защищён.
class DefaultPeerPriorityPolicy implements PeerPriorityPolicy {
  const DefaultPeerPriorityPolicy();

  @override
  int priorityOf(PeerId peerId) => 0;

  @override
  bool isProtected(PeerId peerId) => false;
}

/// Политика с явными наборами приоритетов и защищённых peer'ов.
///
/// Верхний слой (активные группы/каналы) обновляет наборы через [replace]
/// при изменении активности. Это позволяет транспорту вытеснять менее
/// важные ссылки, не зная о доменной модели групп.
class StaticPeerPriorityPolicy implements PeerPriorityPolicy {
  StaticPeerPriorityPolicy({
    Set<PeerId> protectedPeers = const <PeerId>{},
    Map<PeerId, int> priorities = const <PeerId, int>{},
  }) : _protected = Set<PeerId>.unmodifiable(protectedPeers),
       _priorities = Map<PeerId, int>.unmodifiable(priorities);

  Set<PeerId> _protected;
  Map<PeerId, int> _priorities;

  /// Атомарно заменяет наборы. Можно передать только один из них.
  void replace({Set<PeerId>? protectedPeers, Map<PeerId, int>? priorities}) {
    if (protectedPeers != null) {
      _protected = Set<PeerId>.unmodifiable(protectedPeers);
    }
    if (priorities != null) {
      _priorities = Map<PeerId, int>.unmodifiable(priorities);
    }
  }

  @override
  int priorityOf(PeerId peerId) => _priorities[peerId] ?? 0;

  @override
  bool isProtected(PeerId peerId) => _protected.contains(peerId);
}

/// Решение о вытеснении.
@immutable
class LinkEviction {
  const LinkEviction({required this.peerId, required this.priority});

  final PeerId peerId;
  final int priority;
}
