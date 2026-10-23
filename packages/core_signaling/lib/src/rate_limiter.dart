import 'dart:math' as math;

/// Простой token bucket. Обновляет состояние лениво, без таймеров.
class TokenBucket {
  TokenBucket({
    required this.capacity,
    required this.refillPerSecond,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _tokens = capacity.toDouble(),
       _lastRefill = (clock ?? DateTime.now)();

  final int capacity;
  final double refillPerSecond;
  final DateTime Function() _clock;

  double _tokens;
  DateTime _lastRefill;

  bool tryConsume([int amount = 1]) {
    if (amount <= 0) {
      return true;
    }
    _refill();
    if (_tokens < amount) {
      return false;
    }
    _tokens -= amount;
    return true;
  }

  void _refill() {
    final now = _clock();
    final elapsedMs = now.difference(_lastRefill).inMilliseconds;
    if (elapsedMs <= 0) {
      return;
    }
    _lastRefill = now;
    final added = (elapsedMs / 1000.0) * refillPerSecond;
    _tokens = math.min(capacity.toDouble(), _tokens + added);
  }
}
