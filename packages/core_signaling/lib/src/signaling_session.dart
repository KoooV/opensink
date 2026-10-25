import 'dart:async';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:meta/meta.dart';

import 'secure_signaling_codec.dart';
import 'signaling_types.dart';
import 'signaling_utils.dart';

/// Общая часть Nostr/Tracker каналов: шифрование, presence, replay, таймеры.
abstract class SignalingSession
    implements RichSignalingChannel, NeighborAnnouncer {
  SignalingSession({
    required this.security,
    required NodeCapabilities capabilities,
    this.limits = const SignalingLimits(),
    this.helloInterval = const Duration(seconds: 20),
    this.presenceTtl = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _capabilities = _normalizeCapabilities(capabilities),
       _clock = clock ?? DateTime.now,
       codec = SecureSignalingCodec(
         security: security,
         limits: limits,
         clock: clock,
       );

  final SignalingSecurityConfig security;
  NodeCapabilities _capabilities;

  static NodeCapabilities _normalizeCapabilities(NodeCapabilities value) {
    return NodeCapabilities(
      platform: value.platform,
      publicIpv6: value.publicIpv6,
      uptime: value.uptime,
      canRelay: value.canRelay,
      canSfu: value.canSfu,
      capacityBytesPerSecond: value.capacityBytesPerSecond,
      neighbors: List<PeerId>.unmodifiable(value.neighbors),
    );
  }

  NodeCapabilities get capabilities => _capabilities;
  final SignalingLimits limits;
  final Duration helloInterval;
  final Duration presenceTtl;
  final DateTime Function() _clock;
  final SecureSignalingCodec codec;

  final StreamController<SignalingPacket> _packetController =
      StreamController<SignalingPacket>.broadcast();
  final StreamController<PeerPresence> _presenceController =
      StreamController<PeerPresence>.broadcast();
  final Map<String, String> _joinedTopics = <String, String>{};
  final Map<String, PeerPresence> _presence = <String, PeerPresence>{};

  late final Stream<SignalingMessage> _incoming = _packetController.stream.map(
    (packet) => SignalingMessage(
      topic: packet.topic,
      bytes: packet.bytes,
      from: packet.from,
      timestamp: packet.timestamp,
    ),
  );

  Timer? _helloTimer;
  Timer? _presenceTimer;
  DateTime? _lastHelloAt;
  bool _closed = false;

  @override
  Stream<SignalingMessage> get incoming => _incoming;

  @override
  Stream<SignalingPacket> get packets => _packetController.stream;

  @override
  Stream<PeerPresence> get presence => _presenceController.stream;

  bool get isClosed => _closed;

  Set<String> get joinedTopics => Set<String>.unmodifiable(_joinedTopics.keys);

  List<RelayHealth> get relayHealth;

  int get connectedRelayCount;

  @protected
  Future<void> onJoin(String topic);

  @protected
  Future<void> onClose();

  @protected
  Future<void> sendSealed(
    String topic,
    Uint8List sealed, {
    required SignalingKind kind,
    PeerId? to,
  });

  @override
  Future<void> join(String topic) async {
    if (_closed) {
      throw StateError('SignalingSession is closed');
    }
    if (_joinedTopics.containsKey(topic)) {
      return;
    }
    _joinedTopics[topic] = topicHashHex(topic);
    await onJoin(topic);
    _ensureTimers();
    unawaited(_publishHello(force: true));
  }

  @override
  Future<void> publish(String topic, List<int> bytes) =>
      publishTo(topic, kind: SignalingKind.data, bytes: bytes);

  @override
  Future<void> publishTo(
    String topic, {
    required SignalingKind kind,
    PeerId? to,
    required List<int> bytes,
  }) async {
    if (_closed) {
      throw StateError('SignalingSession is closed');
    }
    final sealed = await codec.seal(
      topic: topic,
      kind: kind,
      to: to,
      body: bytes,
    );
    await sendSealed(topic, sealed, kind: kind, to: to);
  }

  /// Вызывается подклассом после установления соединения с очередным реле.
  @protected
  void notifyTransportReady() {
    unawaited(_publishHello());
  }

  @protected
  Future<void> handleSealed(String topic, Uint8List sealed) async {
    final result = await codec.open(sealed, topic: topic);
    if (result is! OpenSignalingOk || _closed) {
      return;
    }
    final opened = result.value;
    if (opened.kind == SignalingKind.hello) {
      final decoded = SecureSignalingCodec.decodeHello(opened.body);
      if (decoded == null) {
        return;
      }
      final now = _clock();
      final peer = PeerPresence(
        topic: topic,
        peerId: opened.from,
        capabilities: decoded,
        seenAt: now,
        expiresAt: now.add(presenceTtl),
      );
      _presence['$topic:${opened.from.publicKey.join(',')}'] = peer;
      if (!_presenceController.isClosed) {
        _presenceController.add(peer);
      }
      return;
    }
    if (!_packetController.isClosed) {
      _packetController.add(
        SignalingPacket(
          topic: topic,
          kind: opened.kind,
          from: opened.from,
          to: opened.to,
          bytes: opened.body,
          timestamp: opened.timestamp,
        ),
      );
    }
  }

  @protected
  String? topicForTag(String tag) {
    for (final entry in _joinedTopics.entries) {
      if (entry.value == tag) {
        return entry.key;
      }
    }
    return null;
  }

  @override
  Future<void> updateNeighbors(Iterable<PeerId> neighbors) async {
    if (_closed) {
      return;
    }
    final unique = <PeerId>[];
    for (final neighbor in neighbors) {
      if (neighbor == security.peerId || unique.contains(neighbor)) {
        continue;
      }
      unique.add(neighbor);
    }
    final current = _capabilities;
    _capabilities = NodeCapabilities(
      platform: current.platform,
      publicIpv6: current.publicIpv6,
      uptime: current.uptime,
      canRelay: current.canRelay,
      canSfu: current.canSfu,
      capacityBytesPerSecond: current.capacityBytesPerSecond,
      neighbors: List<PeerId>.unmodifiable(unique),
    );
    await _publishHello(force: true);
  }

  Future<void> _publishHello({bool force = false}) async {
    if (_closed || _joinedTopics.isEmpty || connectedRelayCount == 0) {
      return;
    }
    final now = _clock();
    final last = _lastHelloAt;
    final debounce = Duration(milliseconds: helloInterval.inMilliseconds ~/ 2);
    if (!force && last != null && now.difference(last) < debounce) {
      return;
    }
    _lastHelloAt = now;
    final body = SecureSignalingCodec.encodeHello(capabilities);
    for (final topic in _joinedTopics.keys) {
      if (_closed) {
        return;
      }
      final sealed = await codec.seal(
        topic: topic,
        kind: SignalingKind.hello,
        body: body,
      );
      await sendSealed(topic, sealed, kind: SignalingKind.hello);
    }
  }

  void _ensureTimers() {
    _helloTimer ??= Timer.periodic(helloInterval, (_) {
      unawaited(_publishHello());
    });
    final pruneInterval = presenceTtl.compareTo(const Duration(seconds: 5)) < 0
        ? presenceTtl
        : const Duration(seconds: 5);
    _presenceTimer ??= Timer.periodic(pruneInterval, (_) {
      final now = _clock();
      _presence.removeWhere((_, presence) => presence.isExpired(now));
    });
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _helloTimer?.cancel();
    _helloTimer = null;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    await onClose();
    _presence.clear();
    await _packetController.close();
    await _presenceController.close();
  }
}
