library;

import 'package:core_domain/core_domain.dart';

/// Правила валидации гибридных логических часов (HLC) на входе в core_sync.
///
/// Выбрано правило 2a: отсекаем немонотонные и слишком старые/будущие
/// метки времени перед записью в лог событий. Монотонность проверяется
/// отдельно по каждому пиару; clock skew ограничивается окном.
class HlcValidator {
  /// Максимально допустимое отклонение hlc от локальных часов (мс).
  ///
  /// 30 секунд — достаточно для дрейфа часов устройств с NTP и без,
  /// но ограничивает окно replay-атак. Для чистого P2P без центрального
  /// источника времени 5 минут слишком велико.
  ///
  /// TODO(verify): измерить реальный дрейф на целевых устройствах
  /// (Android/iOS/Linux/Web) и скорректировать.
  static const int maxClockSkewMs = 30 * 1000; // 30 секунд

  final Map<String, int> _lastHlcByPeer = {};

  /// Валидирует [hlc] от [peerId] относительно текущего времени [nowMs].
  ///
  /// Возвращает [Ok] если метка приемлема, иначе [Err] с [HlcError].
  Result<void, HlcError> validate(String peerId, int hlc, int nowMs) {
    if (hlc < 0) {
      return const Err(NegativeHlc());
    }

    final skew = (hlc - nowMs).abs();
    if (skew > maxClockSkewMs) {
      return Err(ClockSkewExceeded(skew, maxClockSkewMs));
    }

    final last = _lastHlcByPeer[peerId];
    if (last != null && hlc <= last) {
      return Err(NonMonotonicHlc(hlc, last));
    }

    _lastHlcByPeer[peerId] = hlc;
    return const Ok(null);
  }

  /// Сброс состояния для пиара (например, при разрыве сессии).
  void reset(String peerId) {
    _lastHlcByPeer.remove(peerId);
  }

  /// Последняя принятая метка для пиара (или null).
  int? lastHlc(String peerId) => _lastHlcByPeer[peerId];
}

/// Ошибки валидации HLC.
sealed class HlcError {
  const HlcError();
}

class NegativeHlc extends HlcError {
  const NegativeHlc();

  @override
  String toString() => 'NegativeHlc';
}

class ClockSkewExceeded extends HlcError {
  const ClockSkewExceeded(this.actualMs, this.limitMs);

  final int actualMs;
  final int limitMs;

  @override
  String toString() => 'ClockSkewExceeded(actualMs=$actualMs, limitMs=$limitMs)';
}

class NonMonotonicHlc extends HlcError {
  const NonMonotonicHlc(this.hlc, this.lastSeen);

  final int hlc;
  final int lastSeen;

  @override
  String toString() => 'NonMonotonicHlc(hlc=$hlc, lastSeen=$lastSeen)';
}
