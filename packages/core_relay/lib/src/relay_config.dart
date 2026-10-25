import 'package:meta/meta.dart';

/// Платформа узла для выбора политики ретрансляции.
enum RelayPlatform { unknown, android, linux, web }

/// Настройки транспортного релея.
@immutable
class RelayConfig {
  const RelayConfig({
    this.directTimeout = const Duration(seconds: 5),
    this.forwardTimeout = const Duration(seconds: 5),
    this.maxFrameBytes = 192 * 1024,
    this.maxHops = 2,
    this.relayEnabled = false,
    this.perSourceBytesPerSecond = 64 * 1024,
    this.perSourceBurstBytes = 1024 * 1024,
    this.seenTtl = const Duration(minutes: 5),
    this.seenMaxEntries = 4096,
    this.maxSourceEntries = 256,
    this.maxTrackedSources = 256,
    this.incomingBufferFrames = 64,
  });

  /// Сколько ждём прямое ICE-соединение до перехода на релей.
  final Duration directTimeout;

  /// Таймаут отправки кадра следующему хопу.
  final Duration forwardTimeout;

  /// Максимальный размер RelayFrame целиком.
  final int maxFrameBytes;

  /// Начальный TTL и предельное число хопов.
  final int maxHops;

  /// Opt-in: разрешена ли пересылка чужих кадров.
  final bool relayEnabled;

  /// Полоса на один источник (байт/с).
  final int perSourceBytesPerSecond;

  /// Стартовый и максимальный burst на источник.
  final int perSourceBurstBytes;

  /// Время жизни записи в кэше виденных кадров.
  ///
  /// Дедупликация best-effort: после [seenTtl] кадр с тем же nonce снова
  /// принимается. Групповые события защищены собственным дедупом в
  /// `core_sync`, остальные payload обязаны иметь свой идентификатор.
  final Duration seenTtl;

  /// Предел числа записей кэша.
  final int seenMaxEntries;

  /// Сколько входящих payload'ов буферизуется до первой подписки на
  /// `RelayTransport.incoming`. `0` отключает буфер: такие кадры теряются.
  final int incomingBufferFrames;

  /// Предел числа token bucket'ов (LRU) по источникам.
  final int maxSourceEntries;

  /// Предел cardinality метрик по источникам.
  final int maxTrackedSources;

  /// Максимальный payload, который помещается в RelayFrame целиком.
  int get maxPayloadBytes => maxFrameBytes > 160 ? maxFrameBytes - 160 : 0;
}

/// Чистая политика opt-in для UI/настроек.
///
/// На Android ретрансляция по умолчанию не включается в мобильной сети или
/// при низком заряде. Явное согласие пользователя обязательно на всех
/// платформах.
class RelayOptIn {
  const RelayOptIn();

  static const double androidLowBattery = 0.2;

  bool shouldEnable({
    required RelayPlatform platform,
    required bool userConsent,
    required bool metered,
    required double batteryLevel,
  }) {
    if (!userConsent) {
      return false;
    }
    if (platform == RelayPlatform.android &&
        (metered || batteryLevel < androidLowBattery)) {
      return false;
    }
    return true;
  }
}
