import 'package:meta/meta.dart';

/// Имена каналов данных, используемых peer-слоем.
abstract final class PeerChannels {
  static const control = 'control';
  static const sync = 'sync';
  static const file = 'file';
  static const presence = 'presence';
  static const relay = 'relay';

  static const all = <String>[control, sync, file, presence, relay];
}

/// Описание публичного STUN-сервера.
@immutable
class IceServerConfig {
  const IceServerConfig({required this.urls, this.username, this.credential});

  final List<String> urls;
  final String? username;
  final String? credential;

  Map<String, dynamic> toRtcMap() => <String, dynamic>{
    'urls': urls,
    if (username != null) 'username': username,
    if (credential != null) 'credential': credential,
  };
}

/// Публичные STUN по умолчанию.
///
/// Smoke-тест `apps/app/integration_test/stun_smoke_test.dart` подтвердил
/// получение srflx-кандидата через этот список (2026-10-23). В сети с
/// блокировкой UDP/STUN список нужно переопределить через конфиг.
const defaultPublicStun = <IceServerConfig>[
  IceServerConfig(urls: ['stun:stun.l.google.com:19302']),
  IceServerConfig(urls: ['stun:stun1.l.google.com:19302']),
  IceServerConfig(urls: ['stun:stun.cloudflare.com:3478']),
];

/// Параметры прямого WebRTC-соединения.
///
/// Все таймауты намеренно снаружи алгоритма, чтобы тесты могли уменьшать их.
@immutable
class PeerConnectionConfig {
  const PeerConnectionConfig({
    this.iceServers = defaultPublicStun,
    this.connectTimeout = const Duration(seconds: 20),
    this.iceRestartTimeout = const Duration(seconds: 15),
    this.disconnectedGrace = const Duration(seconds: 3),
    this.statsInterval = const Duration(seconds: 2),
    this.maxConcurrentLinks = 16,
    this.maxReconnectAttempts = 5,
    this.reconnectBaseDelay = const Duration(milliseconds: 500),
    this.reconnectMaxDelay = const Duration(seconds: 30),
    this.bufferedAmountHighWater = 1024 * 1024,
    this.bufferedAmountLowThreshold = 256 * 1024,
    this.maxMessageBytes = 256 * 1024,
    this.enableUnreliablePresence = true,
    this.iceCandidatePoolSize = 4,
    this.autoConnectOnSend = false,
  });

  final List<IceServerConfig> iceServers;
  final Duration connectTimeout;
  final Duration iceRestartTimeout;
  final Duration disconnectedGrace;
  final Duration statsInterval;
  final int maxConcurrentLinks;
  final int maxReconnectAttempts;
  final Duration reconnectBaseDelay;
  final Duration reconnectMaxDelay;
  final int bufferedAmountHighWater;
  final int bufferedAmountLowThreshold;
  final int maxMessageBytes;
  final bool enableUnreliablePresence;

  /// IPv6-кандидаты не фильтруются: политику задаёт браузер (web) или
  /// libwebrtc (native). Отдельного флага нет, чтобы не создавать no-op API.
  final int iceCandidatePoolSize;

  /// Если true, транспорт сам инициирует соединение при send.
  final bool autoConnectOnSend;

  Map<String, dynamic> toRtcConfiguration() => <String, dynamic>{
    'iceServers': iceServers.map((server) => server.toRtcMap()).toList(),
    'sdpSemantics': 'unified-plan',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'iceCandidatePoolSize': iceCandidatePoolSize,
  };
}
