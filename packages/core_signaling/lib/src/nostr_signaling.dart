import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart' show bytesToHex;
import 'package:core_domain/core_domain.dart';

import 'expiring_set.dart';
import 'rate_limiter.dart';
import 'nostr_event.dart';
import 'signaling_session.dart';
import 'signaling_types.dart';
import 'signaling_utils.dart';
import 'websocket_pool.dart';

/// Список реле: приглашение имеет приоритет, затем дефолтный конфиг.
class NostrRelayConfig {
  NostrRelayConfig({
    Iterable<Uri> invitationRelays = const <Uri>[],
    Iterable<Uri>? defaultRelays,
    this.maxRelays = 5,
  }) : relays = _merge(
         invitationRelays,
         defaultRelays ?? _publicRelays,
         maxRelays,
       );

  final List<Uri> relays;
  final int maxRelays;

  // TODO(verify): актуальность и политика публичных реле (NIP-11) на момент
  // релиза. Список конфигурируемый; тесты его не используют.
  static final List<Uri> _publicRelays = <Uri>[
    Uri.parse('wss://relay.damus.io'),
    Uri.parse('wss://nos.lol'),
    Uri.parse('wss://relay.nostr.band'),
    Uri.parse('wss://relay.snort.social'),
    Uri.parse('wss://relay.primal.net'),
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

/// SignalingChannel через пул Nostr-реле.
class NostrSignaling extends SignalingSession {
  NostrSignaling({
    required super.security,
    NostrRelayConfig? relays,
    super.capabilities = const NodeCapabilities(),
    super.limits = const SignalingLimits(),
    super.helloInterval = const Duration(seconds: 20),
    super.presenceTtl = const Duration(seconds: 60),
    ReconnectPolicy reconnectPolicy = const ReconnectPolicy(),
    WebSocketConnector? connector,
    super.clock,
  }) : _relayConfig = relays ?? NostrRelayConfig(),
       _clock = clock ?? DateTime.now {
    _pool = WebSocketRelayPool(
      relayUris: _relayConfig.relays,
      onOpen: _onRelayOpen,
      onText: _onRelayText,
      connector: connector,
      policy: reconnectPolicy,
      clock: _clock,
      maxRelays: _relayConfig.maxRelays,
    );
    _seenEvents = ExpiringSet(
      ttl: limits.replayTtl,
      maxEntries: limits.replayMaxEntries,
      clock: _clock,
    );
    _eventBucket = TokenBucket(
      capacity: limits.rateCapacity,
      refillPerSecond: limits.rateRefillPerSecond,
      clock: _clock,
    );
  }

  static const int ephemeralKind = 21000;
  static const int ephemeralKindMin = 20000;
  static const int ephemeralKindMax = 29999;

  final NostrRelayConfig _relayConfig;
  final DateTime Function() _clock;
  late final WebSocketRelayPool _pool;
  late final ExpiringSet _seenEvents;
  late final TokenBucket _eventBucket;
  final Map<String, String> _subscriptionIds = <String, String>{};
  bool _started = false;
  int _subscriptionCounter = 0;

  @override
  List<RelayHealth> get relayHealth => _pool.health;

  @override
  int get connectedRelayCount => _pool.connectedCount;

  @override
  Future<void> onJoin(String topic) async {
    _subscriptionIds[topic] = _newSubscriptionId(topic);
    if (!_started) {
      _started = true;
      _pool.start();
      return;
    }
    _sendSubscription(topic);
  }

  @override
  Future<void> onClose() async {
    for (final entry in _subscriptionIds.entries) {
      final message = jsonEncode(<Object?>['CLOSE', entry.value]);
      _pool.sendTextToAll(message);
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
    final tags = <List<String>>[
      <String>['t', topicHashHex(topic)],
    ];
    if (to != null) {
      tags.add(<String>['p', bytesToHex(to.publicKey)]);
    }
    final signer = _ephemeralSigner;
    if (signer == null) {
      throw StateError('NostrSignaling is closed');
    }
    final event = signer.sign(
      kind: ephemeralKind,
      tags: tags,
      content: base64Encode(sealed),
      createdAt: _clock().millisecondsSinceEpoch ~/ 1000,
    );
    if (event == null) {
      throw StateError('Failed to sign Nostr event');
    }
    _pool.sendTextToAll(jsonEncode(<Object?>['EVENT', event.toJson()]));
  }

  NostrEphemeralSigner? _ephemeralSignerCache;

  NostrEphemeralSigner? get _ephemeralSigner {
    if (isClosed) {
      return null;
    }
    return _ephemeralSignerCache ??= NostrEphemeralSigner.generate();
  }

  void _onRelayOpen(RelayConnection connection) {
    for (final topic in joinedTopics) {
      _sendSubscription(topic, connection: connection);
    }
    notifyTransportReady();
  }

  void _sendSubscription(String topic, {RelayConnection? connection}) {
    final id = _subscriptionIds[topic];
    if (id == null) {
      return;
    }
    final filter = <String, Object?>{
      'kinds': <int>[ephemeralKind],
      '#t': <String>[topicHashHex(topic)],
      'since': _clock().millisecondsSinceEpoch ~/ 1000 - 60,
      'limit': 64,
    };
    final message = jsonEncode(<Object?>['REQ', id, filter]);
    if (connection != null) {
      connection.sendText(message);
    } else {
      _pool.sendTextToAll(message);
    }
  }

  String _newSubscriptionId(String topic) {
    _subscriptionCounter++;
    final suffix = topicHashHex(topic).substring(0, 12);
    return 'os$suffix${_subscriptionCounter.toRadixString(16)}';
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
    if (decoded is! List || decoded.isEmpty) {
      return;
    }
    final action = decoded.first;
    if (action == 'EVENT' && decoded.length >= 2) {
      final eventJson = decoded.length >= 3 ? decoded[2] : decoded[1];
      final event = NostrEvent.fromJson(eventJson);
      if (event != null) {
        unawaited(_handleNostrEvent(event));
      }
    } else if (action == 'NOTICE' ||
        action == 'OK' ||
        action == 'EOSE' ||
        action == 'CLOSED') {
      // Служебные сообщения реле не влияют на доменное состояние.
    }
  }

  Future<void> _handleNostrEvent(NostrEvent event) async {
    if (!_eventBucket.tryConsume()) {
      return;
    }
    if (event.kind < ephemeralKindMin || event.kind > ephemeralKindMax) {
      return;
    }
    if (!event.hasValidId() || !event.hasValidSignature()) {
      return;
    }
    String? topic;
    for (final tag in event.tags) {
      if (tag.length >= 2 && tag[0] == 't') {
        topic = topicForTag(tag[1]);
        if (topic != null) {
          break;
        }
      }
    }
    if (topic == null) {
      return;
    }
    if (!_seenEvents.add(event.id)) {
      return;
    }
    final maxEncoded = (limits.maxPacketBytes * 4 ~/ 3) + 16;
    if (event.content.length > maxEncoded) {
      return;
    }
    Uint8List packet;
    try {
      packet = Uint8List.fromList(base64Decode(event.content));
    } catch (_) {
      return;
    }
    await handleSealed(topic, packet);
  }
}
