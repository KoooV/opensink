import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:web_socket/web_socket.dart';

import 'signaling_types.dart';

/// Абстракция подключения WebSocket (для тестов и платформ).
abstract interface class WebSocketConnector {
  Future<WebSocket> connect(Uri uri);
}

/// Реализация по умолчанию: `package:web_socket` сам выбирает dart:io /
/// dart:js_interop через conditional import внутри пакета.
class DefaultWebSocketConnector implements WebSocketConnector {
  const DefaultWebSocketConnector();

  @override
  Future<WebSocket> connect(Uri uri) => WebSocket.connect(uri);
}

/// Политика переподключения с экспоненциальным backoff и jitter.
@immutable
class ReconnectPolicy {
  const ReconnectPolicy({
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 30),
    this.jitterFraction = 0.25,
    this.connectTimeout = const Duration(seconds: 10),
  });

  final Duration baseDelay;
  final Duration maxDelay;
  final double jitterFraction;
  final Duration connectTimeout;
}

/// Одно реле и его состояние.
class RelayConnection {
  RelayConnection(this.uri);

  final Uri uri;

  WebSocket? _socket;
  // Отменяется в RelayConnection.dispose().
  // ignore: cancel_subscriptions
  StreamSubscription<WebSocketEvent>? _subscription;
  Timer? _reconnectTimer;
  bool connecting = false;
  bool closed = false;

  // Не подключённое реле не считается здоровым; score растёт после connect
  // и успешных сообщений, падает при разрыве/ошибке.
  double healthScore = 0.0;
  int consecutiveFailures = 0;
  int totalFailures = 0;
  int totalConnections = 0;
  DateTime? lastConnectedAt;
  DateTime? lastMessageAt;
  String? lastError;

  bool get isConnected => _socket != null;

  bool sendText(String text) {
    final socket = _socket;
    if (socket == null) {
      return false;
    }
    try {
      socket.sendText(text);
      _bump(0.02);
      return true;
    } catch (error) {
      lastError = error.toString();
      return false;
    }
  }

  Future<void> dispose() async {
    closed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final subscription = _subscription;
    _subscription = null;
    final socket = _socket;
    _socket = null;
    await subscription?.cancel();
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {
        // Соединение уже закрыто другой стороной.
      }
    }
  }

  RelayHealth snapshot() => RelayHealth(
    uri: uri,
    connected: isConnected,
    score: healthScore,
    consecutiveFailures: consecutiveFailures,
    totalFailures: totalFailures,
    totalConnections: totalConnections,
    lastConnectedAt: lastConnectedAt,
    lastMessageAt: lastMessageAt,
    lastError: lastError,
  );

  void _bump(double delta) {
    healthScore = (healthScore + delta).clamp(0.0, 1.0);
  }

  void _penalize() {
    healthScore = (healthScore - 0.25).clamp(0.0, 1.0);
  }
}

/// Пул реле с параллельными подключениями, reconnect и health-score.
class WebSocketRelayPool {
  WebSocketRelayPool({
    required Iterable<Uri> relayUris,
    required this.onOpen,
    required this.onText,
    WebSocketConnector? connector,
    this.policy = const ReconnectPolicy(),
    DateTime Function()? clock,
    Random? random,
    int maxRelays = 5,
  }) : _connector = connector ?? const DefaultWebSocketConnector(),
       _clock = clock ?? DateTime.now,
       _random = random ?? Random(),
       connections = _uniqueUris(relayUris)
           .take(maxRelays)
           .map(RelayConnection.new)
           .toList(growable: false);

  final void Function(RelayConnection connection) onOpen;
  final void Function(RelayConnection connection, String text) onText;
  final ReconnectPolicy policy;
  final WebSocketConnector _connector;
  final DateTime Function() _clock;
  final Random _random;

  final List<RelayConnection> connections;

  bool _closed = false;

  int get connectedCount => connections.where((c) => c.isConnected).length;

  List<RelayHealth> get health =>
      List<RelayHealth>.unmodifiable(connections.map((c) => c.snapshot()));

  /// Запускает параллельные подключения. Не ждёт установления связи.
  void start() {
    if (_closed) {
      return;
    }
    for (final connection in connections) {
      unawaited(_connect(connection));
    }
  }

  /// Отправляет текст во все подключённые реле. Возвращает число успешных.
  int sendTextToAll(String text) {
    var sent = 0;
    for (final connection in connections) {
      if (connection.sendText(text)) {
        sent++;
      }
    }
    return sent;
  }

  bool sendText(Uri uri, String text) {
    for (final connection in connections) {
      if (connection.uri == uri) {
        return connection.sendText(text);
      }
    }
    return false;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final connection in connections) {
      await connection.dispose();
    }
  }

  Future<void> _connect(RelayConnection connection) async {
    if (_closed ||
        connection.closed ||
        connection.connecting ||
        connection.isConnected) {
      return;
    }
    connection.connecting = true;
    try {
      final socket = await _connector
          .connect(connection.uri)
          .timeout(policy.connectTimeout);
      if (_closed || connection.closed) {
        await socket.close();
        return;
      }
      connection._socket = socket;
      connection.totalConnections++;
      connection.consecutiveFailures = 0;
      connection.lastConnectedAt = _clock();
      connection.lastError = null;
      connection._bump(0.20);
      connection._subscription = socket.events.listen(
        (event) => _onEvent(connection, event),
        onError: (Object error, StackTrace stackTrace) {
          _handleDisconnect(connection, error.toString());
        },
        onDone: () {
          _handleDisconnect(connection, null);
        },
      );
      try {
        onOpen(connection);
      } catch (error) {
        connection.lastError = error.toString();
      }
    } catch (error) {
      connection.lastError = error.toString();
      connection._penalize();
      connection.totalFailures++;
      connection.consecutiveFailures++;
      _scheduleReconnect(connection);
    } finally {
      connection.connecting = false;
    }
  }

  void _onEvent(RelayConnection connection, WebSocketEvent event) {
    switch (event) {
      case TextDataReceived(:final text):
        connection.lastMessageAt = _clock();
        connection._bump(0.08);
        try {
          onText(connection, text);
        } catch (error) {
          connection.lastError = error.toString();
        }
      case BinaryDataReceived():
        // Протоколы Nostr и WebTorrent используют text frames.
        break;
      case CloseReceived(:final code, :final reason):
        _handleDisconnect(connection, 'closed: $code $reason');
    }
  }

  void _handleDisconnect(RelayConnection connection, String? error) {
    if (connection._socket == null) {
      return;
    }
    connection._socket = null;
    final subscription = connection._subscription;
    connection._subscription = null;
    unawaited(subscription?.cancel());
    if (error != null) {
      connection.lastError = error;
    }
    connection._penalize();
    connection.totalFailures++;
    connection.consecutiveFailures++;
    _scheduleReconnect(connection);
  }

  void _scheduleReconnect(RelayConnection connection) {
    if (_closed || connection.closed) {
      return;
    }
    connection._reconnectTimer?.cancel();
    final exponent = connection.consecutiveFailures.clamp(1, 12);
    final baseMs = policy.baseDelay.inMilliseconds * pow(2, exponent - 1);
    final cappedMs = min<double>(
      baseMs.toDouble(),
      policy.maxDelay.inMilliseconds.toDouble(),
    );
    final jitter = 1 + (_random.nextDouble() * 2 - 1) * policy.jitterFraction;
    final delayMs = max<int>(1, (cappedMs * jitter).round());
    connection._reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      connection._reconnectTimer = null;
      unawaited(_connect(connection));
    });
  }

  static Iterable<Uri> _uniqueUris(Iterable<Uri> uris) {
    final seen = <String>{};
    final result = <Uri>[];
    for (final uri in uris) {
      if (seen.add(uri.toString())) {
        result.add(uri);
      }
    }
    return result;
  }
}
