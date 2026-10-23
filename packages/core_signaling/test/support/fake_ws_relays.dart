import 'dart:async';
import 'dart:convert';

import 'package:core_signaling/core_signaling.dart';
import 'package:web_socket/testing.dart';
import 'package:web_socket/web_socket.dart';

/// Браузеро-совместимое fake-реле на `package:web_socket` (без dart:io).
///
/// Использует `fakes()` из `package:web_socket/testing.dart`: клиентская
/// сторона отдаётся signaling-каналу, серверная — обслуживается здесь.
class FakeNostrBusRelay implements WebSocketConnector {
  final List<_NostrBusClient> _clients = <_NostrBusClient>[];

  Map<String, Object?>? lastFilter;
  Map<String, Object?>? lastEvent;

  int get connectionCount => _clients.length;

  @override
  Future<WebSocket> connect(Uri uri) async {
    final (client, server) = fakes();
    final busClient = _NostrBusClient(server);
    _clients.add(busClient);
    server.events.listen(
      (event) {
        if (event is TextDataReceived) {
          _onMessage(busClient, event.text);
        }
      },
      onDone: () => _clients.remove(busClient),
      onError: (_) => _clients.remove(busClient),
    );
    return client;
  }

  Future<void> stop() async {
    final clients = List<_NostrBusClient>.of(_clients);
    _clients.clear();
    for (final client in clients) {
      try {
        await client.socket.close();
      } catch (_) {
        // Уже закрыт другой стороной.
      }
    }
  }

  void _onMessage(_NostrBusClient client, String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! List || decoded.isEmpty) {
      return;
    }
    final action = decoded.first;
    if (action == 'REQ' && decoded.length >= 3) {
      final subId = decoded[1];
      final filter = decoded[2];
      if (subId is String && filter is Map) {
        final parsed = Map<String, Object?>.from(filter);
        client.subscriptions[subId] = parsed;
        lastFilter = parsed;
        _send(client.socket, jsonEncode(<Object?>['EOSE', subId]));
      }
    } else if (action == 'CLOSE' && decoded.length >= 2) {
      final subId = decoded[1];
      if (subId is String) {
        client.subscriptions.remove(subId);
      }
    } else if (action == 'EVENT' && decoded.length >= 2) {
      final event = decoded[1];
      if (event is! Map) {
        return;
      }
      final map = Map<String, Object?>.from(event);
      lastEvent = map;
      final id = map['id'];
      if (id is String) {
        _send(client.socket, jsonEncode(<Object?>['OK', id, true, '']));
      }
      _broadcast(map, except: client);
    }
  }

  void _broadcast(Map<String, Object?> event, {_NostrBusClient? except}) {
    for (final client in _clients) {
      if (identical(client, except)) {
        continue;
      }
      for (final entry in client.subscriptions.entries) {
        if (_matches(entry.value, event)) {
          _send(
            client.socket,
            jsonEncode(<Object?>['EVENT', entry.key, event]),
          );
        }
      }
    }
  }

  void _send(WebSocket socket, String message) {
    try {
      socket.sendText(message);
    } catch (_) {
      // Сокет закрылся между проверкой и отправкой.
    }
  }

  bool _matches(Map<String, Object?> filter, Map<String, Object?> event) {
    final kinds = filter['kinds'];
    if (kinds is List && !kinds.contains(event['kind'])) {
      return false;
    }
    final tags = event['tags'];
    if (tags is! List) {
      return false;
    }
    final wanted = filter['#t'];
    if (wanted is List) {
      final values = <String>{};
      for (final tag in tags) {
        if (tag is List &&
            tag.length >= 2 &&
            tag[0] == 't' &&
            tag[1] is String) {
          values.add(tag[1] as String);
        }
      }
      if (!wanted.any(values.contains)) {
        return false;
      }
    }
    return true;
  }
}

class _NostrBusClient {
  _NostrBusClient(this.socket);

  final WebSocket socket;
  final Map<String, Map<String, Object?>> subscriptions =
      <String, Map<String, Object?>>{};
}

/// Браузеро-совместимое fake WebTorrent-трекера на `package:web_socket`.
class FakeTrackerBusRelay implements WebSocketConnector {
  final List<_TrackerBusClient> _clients = <_TrackerBusClient>[];
  final Map<String, Map<String, _TrackerBusPeer>> _swarms =
      <String, Map<String, _TrackerBusPeer>>{};

  int get connectionCount => _clients.length;

  int get peerCount =>
      _swarms.values.fold<int>(0, (sum, swarm) => sum + swarm.length);

  @override
  Future<WebSocket> connect(Uri uri) async {
    final (client, server) = fakes();
    final busClient = _TrackerBusClient(server);
    _clients.add(busClient);
    server.events.listen(
      (event) {
        if (event is TextDataReceived) {
          _onMessage(busClient, event.text);
        }
      },
      onDone: () => _removeClient(busClient),
      onError: (_) => _removeClient(busClient),
    );
    return client;
  }

  Future<void> stop() async {
    final clients = List<_TrackerBusClient>.of(_clients);
    _clients.clear();
    _swarms.clear();
    for (final client in clients) {
      try {
        await client.socket.close();
      } catch (_) {
        // Уже закрыт другой стороной.
      }
    }
  }

  void _onMessage(_TrackerBusClient client, String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map || decoded['action'] != 'announce') {
      return;
    }
    final infoHash = decoded['info_hash'];
    final peerId = decoded['peer_id'];
    if (infoHash is! String || peerId is! String) {
      return;
    }
    final event = decoded['event'];
    final swarm = _swarms.putIfAbsent(
      infoHash,
      () => <String, _TrackerBusPeer>{},
    );
    if (event == 'stopped') {
      swarm.remove(peerId);
      return;
    }
    swarm[peerId] = _TrackerBusPeer(client, peerId);
    client.infoHashes.add(infoHash);

    final answer = decoded['answer'];
    if (answer is Map) {
      final toPeerId = decoded['to_peer_id'];
      if (toPeerId is String) {
        final target = swarm[toPeerId];
        if (target != null) {
          _send(
            target.client.socket,
            jsonEncode(<String, Object?>{
              'action': 'announce',
              'answer': answer,
              'offer_id': decoded['offer_id'],
              'peer_id': peerId,
              'info_hash': infoHash,
            }),
          );
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
        _send(
          targets[i].client.socket,
          jsonEncode(<String, Object?>{
            'action': 'announce',
            'offer': offer['offer'],
            'offer_id': offer['offer_id'],
            'peer_id': peerId,
            'info_hash': infoHash,
          }),
        );
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
    try {
      socket.sendText(message);
    } catch (_) {
      // Сокет закрылся между проверкой и отправкой.
    }
  }

  void _removeClient(_TrackerBusClient client) {
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

class _TrackerBusClient {
  _TrackerBusClient(this.socket);

  final WebSocket socket;
  final Set<String> infoHashes = <String>{};
}

class _TrackerBusPeer {
  _TrackerBusPeer(this.client, this.peerId);

  final _TrackerBusClient client;
  final String peerId;
}
