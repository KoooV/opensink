import 'dart:math' as math;

/// Гибридные логические часы (HLC): физическое время + счётчик.
///
/// Сравнение лексикографическое: сначала [physicalMs], затем [counter].
/// Физическая часть хранится отдельно от счётчика, чтобы значения оставались
/// безопасными для dart2js (никаких 64-битных сдвигов).
class Hlc implements Comparable<Hlc> {
  const Hlc(this.physicalMs, this.counter);

  final int physicalMs;
  final int counter;

  @override
  int compareTo(Hlc other) {
    final byPhysical = physicalMs.compareTo(other.physicalMs);
    if (byPhysical != 0) return byPhysical;
    return counter.compareTo(other.counter);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Hlc &&
          physicalMs == other.physicalMs &&
          counter == other.counter;

  @override
  int get hashCode => Object.hash(physicalMs, counter);

  @override
  String toString() => 'Hlc($physicalMs,$counter)';
}

/// Детерминированные HLC с внедряемым источником физического времени.
class HlcClock {
  HlcClock({int Function()? nowMs, Hlc initial = const Hlc(0, 0)})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
      _last = initial;

  final int Function() _nowMs;
  Hlc _last;

  Hlc get last => _last;

  /// Метка для нового локального события.
  Hlc tick() {
    final now = _nowMs();
    if (now > _last.physicalMs) {
      _last = Hlc(now, 0);
    } else {
      _last = Hlc(_last.physicalMs, _last.counter + 1);
    }
    return _last;
  }

  /// Наблюдение чужой метки: локальные часы всегда обгоняют её.
  Hlc observe(Hlc remote) {
    final now = _nowMs();
    final maxPhysical = math.max(
      now,
      math.max(_last.physicalMs, remote.physicalMs),
    );

    late int counter;
    if (maxPhysical == _last.physicalMs && maxPhysical == remote.physicalMs) {
      counter = math.max(_last.counter, remote.counter) + 1;
    } else if (maxPhysical == _last.physicalMs) {
      counter = _last.counter + 1;
    } else if (maxPhysical == remote.physicalMs) {
      counter = remote.counter + 1;
    } else {
      counter = 0;
    }

    _last = Hlc(maxPhysical, counter);
    return _last;
  }
}
