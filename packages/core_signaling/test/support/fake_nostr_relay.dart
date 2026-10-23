import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Минимальный fake Nostr-реле для VM-тестов (NIP-01 subset).
class FakeNostrRelay {
  FakeNostrRelay._(this._server);

  final HttpServer _server;
  final Set<_NostrClient> _clients = <_NostrClient>{};
  Map<String, Object?>? _lastEvent;
  Map<String, Object?>? _lastFilter;
  bool _stopped = false;

  static Future<FakeNostrRelay> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = FakeNostrRelay._(server);
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      // Закрывается в stop().
      // ignore: close_sinks
      final socket = await WebSocketTransformer.upgrade(request);
      final client = _NostrClient(socket);
      relay._clients.add(client);
      socket.listen(
        (message) {
          if (message is String) {
            relay._onMessage(client, message);
          }
        },
        onDone: () => relay._clients.remove(client),
        onError: (_) => relay._clients.remove(client),
        cancelOnError: true,
      );
    });
    return relay;
  }

  Uri get uri => Uri.parse('ws://${_server.address.address}:${_server.port}');

  int get connectionCount => _clients.length;

  Map<String, Object?>? get lastEvent => _lastEvent;

  /// Последний фильтр REQ, полученный этим реле.
  Map<String, Object?>? get lastFilter => _lastFilter;

  Future<void> replayLastEvent() async {
    final event = _lastEvent;
    if (event == null) {
      return;
    }
    _broadcast(event);
  }

  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    final clients = List<_NostrClient>.of(_clients);
    _clients.clear();
    for (final client in clients) {
      try {
        await client.socket.close();
      } catch (_) {
        // already closed
      }
    }
    await _server.close(force: true);
  }

  void _onMessage(_NostrClient client, String raw) {
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
        _lastFilter = parsed;
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
      _lastEvent = map;
      final id = map['id'];
      if (id is String) {
        _send(client.socket, jsonEncode(<Object?>['OK', id, true, '']));
      }
      _broadcast(map, except: client);
    }
  }

  void _broadcast(Map<String, Object?> event, {_NostrClient? except}) {
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
    if (socket.readyState != WebSocket.open) {
      return;
    }
    try {
      socket.add(message);
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

class _NostrClient {
  _NostrClient(this.socket);

  final WebSocket socket;
  final Map<String, Map<String, Object?>> subscriptions =
      <String, Map<String, Object?>>{};
}
