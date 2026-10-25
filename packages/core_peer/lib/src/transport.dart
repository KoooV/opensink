import 'dart:async';
import 'dart:math';

// ignore_for_file: prefer_initializing_formals

import 'package:core_domain/core_domain.dart';
import 'package:core_signaling/core_signaling.dart';

import 'config.dart';
import 'errors.dart';
import 'network_change.dart';
import 'peer_link.dart';
import 'policy.dart';
import 'rtc/rtc_types.dart';
import 'signaling/peer_signal.dart';

/// Транспорт прямых соединений поверх signaling-слоя 5.
///
/// Не реализует relay-маршрутизацию: это отдельный слой core_relay.
class WebRtcTransport implements Transport {
  WebRtcTransport({
    required this.localPeerId,
    required this.signaling,
    required this.topic,
    this.config = const PeerConnectionConfig(),
    required RtcPeerFactory factory,
    NetworkChangeSource? networkChanges,
    PeerPriorityPolicy priorityPolicy = const DefaultPeerPriorityPolicy(),
    Random? random,
  }) : _factory = factory,
       _networkChanges = networkChanges,
       _priorityPolicy = priorityPolicy,
       _random = random ?? Random();

  final PeerId localPeerId;
  final RichSignalingChannel signaling;
  final String topic;
  final PeerConnectionConfig config;

  final RtcPeerFactory _factory;
  final NetworkChangeSource? _networkChanges;
  final PeerPriorityPolicy _priorityPolicy;
  final Random _random;

  final StreamController<PeerLinkEvent> _events =
      StreamController<PeerLinkEvent>.broadcast();
  final StreamController<RelayDatagram> _relayIncoming =
      StreamController<RelayDatagram>.broadcast();
  final Map<PeerId, WebRtcPeerLink> _links = <PeerId, WebRtcPeerLink>{};
  final Map<PeerId, StreamSubscription<PeerLinkState>> _linkStates =
      <PeerId, StreamSubscription<PeerLinkState>>{};
  final Map<PeerId, StreamSubscription<Incoming>> _linkIncoming =
      <PeerId, StreamSubscription<Incoming>>{};
  final Set<String> _joinedTopics = <String>{};
  final Set<PeerId> _accepting = <PeerId>{};

  StreamSubscription<SignalingPacket>? _packetSubscription;
  StreamSubscription<void>? _networkSubscription;
  Future<void>? _starting;
  bool _closed = false;

  /// Очередь приёма новых линков.
  ///
  /// Сериализует проверку лимита, вытеснение и добавление в [_links],
  /// чтобы параллельные `connect`/`acceptOffer` не выбились за
  /// `maxConcurrentLinks` и не создали две ссылки на одного пира.
  Future<void> _admissionTail = Future<void>.value();

  Future<T> _admit<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _admissionTail = _admissionTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  @override
  Stream<PeerLinkEvent> get events => _events.stream;

  @override
  Stream<RelayDatagram> get relayIncoming => _relayIncoming.stream;

  Map<PeerId, PeerLink> get links => Map<PeerId, PeerLink>.unmodifiable(_links);

  PeerLink? linkFor(PeerId peerId) => _links[peerId];

  @override
  PeerLinkStats? statsFor(PeerId peerId) => linkFor(peerId)?.stats;

  Future<void> start() => _ensureStarted();

  Future<void> joinTopic(String topic) async {
    if (_closed) {
      throw StateError('WebRtcTransport is closed');
    }
    if (_joinedTopics.add(topic)) {
      await signaling.join(topic);
    }
  }

  Future<void> _ensureStarted() {
    return _starting ??= _startInternal();
  }

  Future<void> _startInternal() async {
    if (_closed) {
      throw StateError('WebRtcTransport is closed');
    }
    _packetSubscription = signaling.packets.listen(_onPacket);
    _networkSubscription = _networkChanges?.changes.listen((_) {
      notifyNetworkChanged();
    });
    await joinTopic(topic);
  }

  @override
  Future<PeerLink> connect(PeerId peerId) => connectTo(peerId, topic);

  Future<PeerLink> connectTo(PeerId peerId, String topic) async {
    await _ensureStarted();
    await joinTopic(topic);
    final link = await _admit<WebRtcPeerLink>(() async {
      if (peerId == localPeerId) {
        throw const PeerSignalingError('cannot connect to self');
      }
      final existing = _links[peerId];
      if (existing != null &&
          existing.state != PeerLinkState.closed &&
          existing.state != PeerLinkState.failed) {
        return existing;
      }
      if (existing != null) {
        await _removeLink(peerId);
      }

      final newPriority = _priorityPolicy.priorityOf(peerId);
      if (!await _makeRoom(peerId, newPriority)) {
        throw PeerCapacityExceeded(config.maxConcurrentLinks);
      }

      final created = _createLink(
        peerId: peerId,
        topic: topic,
        initiate: true,
      );
      _links[peerId] = created;
      _watchLink(created);
      return created;
    });
    try {
      if (link.state != PeerLinkState.connected) {
        await link.start();
      }
      await link.waitUntilConnected();
      return link;
    } catch (error) {
      try {
        await _removeLink(peerId).timeout(const Duration(seconds: 3));
      } catch (_) {
        _links.remove(peerId);
      }
      rethrow;
    }
  }

  @override
  Future<void> send(PeerId dst, List<int> bytes) =>
      _sendOn(dst, bytes, PeerChannels.control);

  @override
  Future<void> sendRelay(PeerId dst, List<int> bytes) =>
      _sendOn(dst, bytes, PeerChannels.relay);

  Future<void> _sendOn(PeerId dst, List<int> bytes, String channel) async {
    final existing = _links[dst];
    if (existing == null ||
        existing.state == PeerLinkState.closed ||
        existing.state == PeerLinkState.failed) {
      if (!config.autoConnectOnSend) {
        throw StateError('No link to peer $dst');
      }
      await connect(dst);
    }
    final link = _links[dst];
    if (link == null ||
        link.state == PeerLinkState.closed ||
        link.state == PeerLinkState.failed) {
      throw StateError('No link to peer $dst');
    }
    await link.send(channel, bytes);
  }

  /// Уведомляет все активные ссылки о смене сети (ICE restart).
  void notifyNetworkChanged() {
    if (_closed) {
      return;
    }
    for (final link in List<WebRtcPeerLink>.of(_links.values)) {
      unawaited(
        link.onNetworkChanged().catchError((Object _) {
          // Ошибка ICE restart приведёт к reconnect внутри ссылки.
        }),
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    await _packetSubscription?.cancel();
    _packetSubscription = null;
    await _networkSubscription?.cancel();
    _networkSubscription = null;
    for (final peerId in List<PeerId>.of(_links.keys)) {
      await _removeLink(peerId, notifyRemote: true);
    }
    _closed = true;
    _links.clear();
    _linkStates.clear();
    _linkIncoming.clear();
    if (!_relayIncoming.isClosed) {
      await _relayIncoming.close();
    }
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  WebRtcPeerLink _createLink({
    required PeerId peerId,
    required String topic,
    required bool initiate,
  }) {
    return WebRtcPeerLink(
      localPeerId: localPeerId,
      remotePeerId: peerId,
      topic: topic,
      factory: _factory,
      config: config,
      initiate: initiate,
      random: _random,
      publishSignal: (signal) => _publish(peerId, topic, signal),
    );
  }

  void _watchLink(WebRtcPeerLink link) {
    final peerId = link.remotePeerId;
    _linkStates[peerId]?.cancel();
    _linkIncoming[peerId]?.cancel();
    _linkIncoming[peerId] = link.incoming.listen((incoming) {
      if (incoming.channel != PeerChannels.relay ||
          _relayIncoming.isClosed) {
        return;
      }
      _relayIncoming.add(
        RelayDatagram(
          from: peerId,
          bytes: incoming.bytes,
          timestamp: incoming.timestamp,
        ),
      );
    });
    _linkStates[peerId] = link.stateStream.listen((state) {
      switch (state) {
        case PeerLinkState.connected:
          _emit('connected', peerId);
        case PeerLinkState.connecting:
          _emit('connecting', peerId);
        case PeerLinkState.failed:
          _emit('error', peerId, const PeerConnectTimeout());
          // После исчерпания попыток ссылка терминальна: освобождает слот.
          unawaited(_removeLink(peerId).catchError((Object _) {
            // Ссылка уже могла быть удалена.
          }));
        case PeerLinkState.closed:
          _emit('disconnected', peerId);
          if (identical(_links[peerId], link)) {
            unawaited(
              _forgetLink(peerId).catchError((Object _) {
                // Ссылка уже могла быть удалена.
              }),
            );
          }
      }
    });
  }

  Future<void> _forgetLink(PeerId peerId) async {
    final subscription = _linkStates.remove(peerId);
    final incoming = _linkIncoming.remove(peerId);
    await subscription?.cancel();
    await incoming?.cancel();
    _links.remove(peerId);
  }

  Future<void> _removeLink(PeerId peerId, {bool notifyRemote = true}) async {
    final link = _links.remove(peerId);
    final subscription = _linkStates.remove(peerId);
    final incoming = _linkIncoming.remove(peerId);
    await subscription?.cancel();
    await incoming?.cancel();
    if (link == null) {
      return;
    }
    if (notifyRemote) {
      await link.close();
    }
  }

  Future<bool> _makeRoom(PeerId peerId, int priority) async {
    if (_links.length < config.maxConcurrentLinks) {
      return true;
    }
    LinkEviction? victim;
    for (final entry in _links.entries) {
      if (entry.key == peerId) {
        continue;
      }
      if (_priorityPolicy.isProtected(entry.key)) {
        continue;
      }
      final candidatePriority = _priorityPolicy.priorityOf(entry.key);
      if (candidatePriority < priority &&
          (victim == null || candidatePriority < victim.priority)) {
        victim = LinkEviction(peerId: entry.key, priority: candidatePriority);
      }
    }
    if (victim == null) {
      return false;
    }
    await _removeLink(victim.peerId, notifyRemote: true);
    _emit('evicted', victim.peerId);
    return true;
  }

  void _onPacket(SignalingPacket packet) {
    if (_closed || !_joinedTopics.contains(packet.topic)) {
      return;
    }
    if (packet.from == localPeerId) {
      return;
    }
    if (packet.to != null && packet.to != localPeerId) {
      return;
    }
    final signal = PeerSignalCodec.decode(packet.bytes);
    if (signal == null) {
      return;
    }
    final peerId = packet.from;
    final link = _links[peerId];
    if (signal.kind == PeerSignalKind.offer) {
      if (packet.to == null) {
        // Broadcast-offer не создаёт соединения со всеми участниками темы.
        return;
      }
      if (link != null) {
        unawaited(_dispatchSignal(link, signal));
      } else {
        unawaited(_acceptOffer(peerId, packet.topic, signal));
      }
      return;
    }
    if (link != null) {
      unawaited(_dispatchSignal(link, signal));
    }
  }

  Future<void> _dispatchSignal(WebRtcPeerLink link, PeerSignal signal) async {
    try {
      await link.handleSignal(signal);
    } catch (_) {
      // Повреждённый или устаревший сигнал не должен ронять транспорт.
    }
  }

  Future<void> _acceptOffer(
    PeerId peerId,
    String topic,
    PeerSignal signal,
  ) async {
    if (!_accepting.add(peerId)) {
      return;
    }
    try {
      final link = await _admit<WebRtcPeerLink?>(() async {
        if (_closed) {
          return null;
        }
        if (!await _makeRoom(peerId, _priorityPolicy.priorityOf(peerId))) {
          _emit('error', peerId, PeerCapacityExceeded(config.maxConcurrentLinks));
          return null;
        }
        final created = _createLink(
          peerId: peerId,
          topic: topic,
          initiate: false,
        );
        _links[peerId] = created;
        _watchLink(created);
        return created;
      });
      if (link == null) {
        return;
      }
      try {
        await link.start();
        await link.handleSignal(signal);
      } catch (error) {
        _emit('error', peerId, error);
        await _removeLink(peerId);
      }
    } finally {
      _accepting.remove(peerId);
    }
  }

  Future<void> _publish(PeerId peerId, String topic, PeerSignal signal) async {
    if (_closed) {
      return;
    }
    await signaling.publishTo(
      topic,
      kind: _wireKind(signal.kind),
      to: peerId,
      bytes: PeerSignalCodec.encode(signal),
    );
  }

  SignalingKind _wireKind(PeerSignalKind kind) => switch (kind) {
    PeerSignalKind.offer => SignalingKind.offer,
    PeerSignalKind.answer => SignalingKind.answer,
    PeerSignalKind.ice => SignalingKind.ice,
    PeerSignalKind.hangup => SignalingKind.hangup,
  };

  void _emit(String type, PeerId? peerId, [Object? error]) {
    if (_events.isClosed) {
      return;
    }
    _events.add(PeerLinkEvent(type, peerId, error));
  }
}
