import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Минимальный fake WebTorrent-трекер для VM-тестов.
class FakeTrackerRelay {
  FakeTrackerRelay._(this._server);

  final HttpServer _server;
  final Set<_TrackerClient> _clients = <_TrackerClient>{};
  final Map<String, Map<String, _TrackerPeer>> _swarms =
      <String, Map<String, _TrackerPeer>>{};
  final List<Map<String, Object?>> _announces = <Map<String, Object?>>[];
  _OfferDelivery? _lastOffer;
  bool _stopped = false;

  static Future<FakeTrackerRelay> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = FakeTrackerRelay._(server);
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      // Закрывается в stop().
      // ignore: close_sinks
      final socket = await WebSocketTransformer.upgrade(request);
      final client = _TrackerClient(socket);
      relay._clients.add(client);
      socket.listen(
        (message) {
          if (message is String) {
            relay._onMessage(client, message);
          }
        },
        onDone: () => relay._removeClient(client),
        onError: (_) => relay._removeClient(client),
        cancelOnError: true,
      );
    });
    return relay;
  }

  Uri get uri => Uri.parse('ws://${_server.address.address}:${_server.port}');

  int get connectionCount => _clients.length;

  int get peerCount =>
      _swarms.values.fold<int>(0, (sum, swarm) => sum + swarm.length);

  /// Все announce-запросы в порядке поступления (wire-формат).
  List<Map<String, Object?>> get announces => List.unmodifiable(_announces);

  Future<void> replayLastOffer() async {
    final last = _lastOffer;
    if (last == null || last.client.socket.readyState != WebSocket.open) {
      return;
    }
    _send(last.client.socket, last.message);
  }

  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    final clients = List<_TrackerClient>.of(_clients);
    _clients.clear();
    _swarms.clear();
    for (final client in clients) {
      try {
        await client.socket.close();
      } catch (_) {
        // already closed
      }
    }
    await _server.close(force: true);
  }

  void _onMessage(_TrackerClient client, String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) {
      return;
    }
    if (decoded['action'] != 'announce') {
      return;
    }
    _announces.add(Map<String, Object?>.from(decoded));
    final infoHash = decoded['info_hash'];
    final peerId = decoded['peer_id'];
    if (infoHash is! String || peerId is! String) {
      return;
    }
    final event = decoded['event'];
    final swarm = _swarms.putIfAbsent(infoHash, () => <String, _TrackerPeer>{});
    if (event == 'stopped') {
      swarm.remove(peerId);
      return;
    }
    swarm[peerId] = _TrackerPeer(client, peerId);
    client.infoHashes.add(infoHash);

    final answer = decoded['answer'];
    if (answer is Map) {
      final toPeerId = decoded['to_peer_id'];
      if (toPeerId is String) {
        final target = swarm[toPeerId];
        if (target != null) {
          final message = jsonEncode(<String, Object?>{
            'action': 'announce',
            'answer': answer,
            'offer_id': decoded['offer_id'],
            'peer_id': peerId,
            'info_hash': infoHash,
          });
          _send(target.client.socket, message);
        }
      }
      return;
    }

    final offers = decoded['offers'];
    if (offers is List) {
      final targets = swarm.entries
          .where((entry) => entry.key != peerId)
          .map((entry) => entry.value)
          .toList(growable: false);
      for (var i = 0; i < offers.length && i < targets.length; i++) {
        final offer = offers[i];
        if (offer is! Map) {
          continue;
        }
        final message = jsonEncode(<String, Object?>{
          'action': 'announce',
          'offer': offer['offer'],
          'offer_id': offer['offer_id'],
          'peer_id': peerId,
          'info_hash': infoHash,
        });
        _send(targets[i].client.socket, message);
        _lastOffer = _OfferDelivery(targets[i].client, message);
      }
    }

    _send(
      client.socket,
      jsonEncode(<String, Object?>{
        'action': 'announce',
        'info_hash': infoHash,
        'complete': 0,
        'incomplete': swarm.length,
        'interval': 120,
      }),
    );
  }

  void _send(WebSocket socket, String message) {
    if (socket.readyState != WebSocket.open) {
      return;
    }
    try {
      socket.add(message);
    } catch (_) {
      // Сокет закрылся между проверкой и отправкой.
    }
  }

  void _removeClient(_TrackerClient client) {
    _clients.remove(client);
    for (final infoHash in client.infoHashes) {
      final swarm = _swarms[infoHash];
      if (swarm == null) {
        continue;
      }
      swarm.removeWhere((_, peer) => identical(peer.client, client));
      if (swarm.isEmpty) {
        _swarms.remove(infoHash);
      }
    }
  }
}

class _TrackerClient {
  _TrackerClient(this.socket);

  final WebSocket socket;
  final Set<String> infoHashes = <String>{};
}

class _TrackerPeer {
  _TrackerPeer(this.client, this.peerId);

  final _TrackerClient client;
  final String peerId;
}

class _OfferDelivery {
  _OfferDelivery(this.client, this.message);

  final _TrackerClient client;
  final String message;
}
