import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';

import 'signaling_session.dart';
import 'signaling_types.dart';
import 'signaling_utils.dart';
import 'websocket_pool.dart';

/// Список WebSocket-трекеров: приглашение имеет приоритет.
class TrackerRelayConfig {
  TrackerRelayConfig({
    Iterable<Uri> invitationRelays = const <Uri>[],
    Iterable<Uri>? defaultRelays,
    this.maxRelays = 5,
  }) : relays = _merge(
         invitationRelays,
         defaultRelays ?? _publicTrackers,
         maxRelays,
       );

  final List<Uri> relays;
  final int maxRelays;

  // TODO(verify): актуальность публичных WebTorrent-трекеров и их политика.
  static final List<Uri> _publicTrackers = <Uri>[
    Uri.parse('wss://tracker.openwebtorrent.com'),
    Uri.parse('wss://tracker.btorrent.xyz'),
    Uri.parse('wss://tracker.webtorrent.dev'),
  ];

  static List<Uri> _merge(
    Iterable<Uri> invitation,
    Iterable<Uri> defaults,
    int maxRelays,
  ) {
    final result = <Uri>[];
    final seen = <String>{};
    for (final uri in <Uri>[...invitation, ...defaults]) {
      if (seen.add(uri.toString())) {
        result.add(uri);
      }
      if (result.length >= maxRelays) {
        break;
      }
    }
    return List<Uri>.unmodifiable(result);
  }
}

/// SignalingChannel через пул WebSocket-трекеров в стиле WebTorrent.
class TrackerSignaling extends SignalingSession {
  TrackerSignaling({
    required super.security,
    TrackerRelayConfig? relays,
    super.capabilities = const NodeCapabilities(),
    super.limits = const SignalingLimits(),
    super.helloInterval = const Duration(seconds: 20),
    super.presenceTtl = const Duration(seconds: 60),
    ReconnectPolicy reconnectPolicy = const ReconnectPolicy(),
    WebSocketConnector? connector,
    super.clock,
    int offersPerAnnounce = 3,
  }) : _relayConfig = relays ?? TrackerRelayConfig(),
       _offersPerAnnounce = offersPerAnnounce.clamp(1, 5),
       _clock = clock ?? DateTime.now,
       _trackerPeerIdString = bytesToBinaryString(
         sha256First20(security.peerId.publicKey),
       ) {
    _pool = WebSocketRelayPool(
      relayUris: _relayConfig.relays,
      onOpen: _onRelayOpen,
      onText: _onRelayText,
      connector: connector,
      policy: reconnectPolicy,
      clock: _clock,
      maxRelays: _relayConfig.maxRelays,
    );
  }

  static const String sdpPrefix = 'opensink:1:';

  final TrackerRelayConfig _relayConfig;
  final int _offersPerAnnounce;
  final String _trackerPeerIdString;
  final DateTime Function() _clock;
  final Map<String, String> _topicsByInfoHash = <String, String>{};
  final Random _random = Random.secure();
  late final WebSocketRelayPool _pool;
  bool _started = false;

  @override
  List<RelayHealth> get relayHealth => _pool.health;

  @override
  int get connectedRelayCount => _pool.connectedCount;

  @override
  Future<void> onJoin(String topic) async {
    _topicsByInfoHash[_infoHashString(topic)] = topic;
    if (!_started) {
      _started = true;
      _pool.start();
      return;
    }
    for (final connection in _pool.connections) {
      if (connection.isConnected) {
        _sendAnnounce(topic, connection: connection, event: 'started');
      }
    }
  }

  @override
  Future<void> onClose() async {
    for (final topic in joinedTopics) {
      _sendAnnounce(topic, event: 'stopped', includeOffers: false);
    }
    await _pool.close();
  }

  @override
  Future<void> sendSealed(
    String topic,
    Uint8List sealed, {
    required SignalingKind kind,
    PeerId? to,
  }) async {
    final encoded = '$sdpPrefix${base64UrlNoPadding(sealed)}';
    if (to != null) {
      _sendAnswer(topic, to, encoded);
      return;
    }
    _sendAnnounce(topic, includeOffers: true, offerSdp: encoded);
  }

  void _onRelayOpen(RelayConnection connection) {
    for (final topic in joinedTopics) {
      _sendAnnounce(topic, connection: connection, event: 'started');
    }
    notifyTransportReady();
  }

  void _onRelayText(RelayConnection connection, String text) {
    if (text.length > limits.maxPacketBytes * 2 + 4096) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is! Map) {
      return;
    }
    if (decoded['action'] != 'announce') {
      return;
    }
    final infoHash = decoded['info_hash'];
    if (infoHash is! String) {
      return;
    }
    final topic = _topicsByInfoHash[infoHash];
    if (topic == null) {
      return;
    }
    final peerId = decoded['peer_id'];
    if (peerId is String && peerId == _trackerPeerIdString) {
      return;
    }
    final offer = decoded['offer'];
    if (offer is Map) {
      final sdp = offer['sdp'];
      if (sdp is String) {
        _handleSdp(topic, sdp);
      }
    }
    final answer = decoded['answer'];
    if (answer is Map) {
      final sdp = answer['sdp'];
      if (sdp is String) {
        _handleSdp(topic, sdp);
      }
    }
  }

  void _handleSdp(String topic, String sdp) {
    if (!sdp.startsWith(sdpPrefix)) {
      return;
    }
    final packet = base64UrlNoPaddingDecode(sdp.substring(sdpPrefix.length));
    if (packet == null) {
      return;
    }
    unawaited(handleSealed(topic, packet));
  }

  void _sendAnnounce(
    String topic, {
    RelayConnection? connection,
    String event = 'update',
    bool includeOffers = true,
    String? offerSdp,
  }) {
    final message = <String, Object?>{
      'action': 'announce',
      'info_hash': _infoHashString(topic),
      'peer_id': _trackerPeerIdString,
      'event': event,
      'uploaded': 0,
      'downloaded': 0,
      'left': 0,
    };
    if (includeOffers && offerSdp != null) {
      message['numwant'] = _offersPerAnnounce;
      message['offers'] = List<Map<String, Object?>>.generate(
        _offersPerAnnounce,
        (_) => <String, Object?>{
          'offer': <String, Object?>{'type': 'offer', 'sdp': offerSdp},
          'offer_id': bytesToBinaryString(_randomBytes(20)),
        },
      );
    } else {
      message['numwant'] = 0;
    }
    final encoded = jsonEncode(message);
    if (connection != null) {
      connection.sendText(encoded);
    } else {
      _pool.sendTextToAll(encoded);
    }
  }

  void _sendAnswer(String topic, PeerId to, String sdp) {
    final message = <String, Object?>{
      'action': 'announce',
      'info_hash': _infoHashString(topic),
      'peer_id': _trackerPeerIdString,
      'to_peer_id': bytesToBinaryString(sha256First20(to.publicKey)),
      'offer_id': bytesToBinaryString(_randomBytes(20)),
      'answer': <String, Object?>{'type': 'answer', 'sdp': sdp},
    };
    _pool.sendTextToAll(jsonEncode(message));
  }

  String _infoHashString(String topic) =>
      bytesToBinaryString(sha256First20(utf8.encode(topic)));

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }
}
