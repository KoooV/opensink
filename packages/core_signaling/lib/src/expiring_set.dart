import 'dart:collection';

/// Набор с TTL и ограничением размера (FIFO-вытеснение).
class ExpiringSet {
  ExpiringSet({
    required this.ttl,
    required this.maxEntries,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _clock;

  final LinkedHashMap<String, DateTime> _entries =
      LinkedHashMap<String, DateTime>();

  bool contains(String key) {
    final expiresAt = _entries[key];
    if (expiresAt == null) {
      return false;
    }
    if (_clock().isBefore(expiresAt)) {
      return true;
    }
    _entries.remove(key);
    return false;
  }

  /// Возвращает `true`, если ключ добавлен впервые (не истёк и не был в наборе).
  bool add(String key) {
    final now = _clock();
    _prune(now);
    final existing = _entries[key];
    if (existing != null && now.isBefore(existing)) {
      return false;
    }
    _entries[key] = now.add(ttl);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return true;
  }

  void remove(String key) => _entries.remove(key);

  void _prune(DateTime now) {
    _entries.removeWhere((_, expiresAt) => !now.isBefore(expiresAt));
  }
}
