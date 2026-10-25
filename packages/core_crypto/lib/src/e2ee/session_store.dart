import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';

/// Ошибки хранения E2E-сессий.
sealed class E2eSessionStoreError {
  const E2eSessionStoreError();
}

/// Хранилище недоступно (инфраструктурная ошибка).
class E2eSessionStoreUnavailable extends E2eSessionStoreError {
  const E2eSessionStoreUnavailable();
}

/// Сохранённое состояние повреждено или вскрыто с неверным контекстом.
class E2eSessionStoreCorrupted extends E2eSessionStoreError {
  const E2eSessionStoreCorrupted();
}

/// Персистентное хранилище сериализованных состояний Double Ratchet.
///
/// Ключ — идентификатор пира (hex Ed25519). Реализация обязана защищать
/// состояние на диске (например, `StateVault` + `SecureKeyStore`); ошибки не
/// должны раскрывать ключевой материал.
abstract class E2eSessionStore {
  /// Загружает состояние пира или `Ok(null)`, если записи нет.
  Future<Result<Uint8List?, E2eSessionStoreError>> load(String peerId);

  /// Сохраняет состояние пира.
  Future<Result<void, E2eSessionStoreError>> save(
    String peerId,
    Uint8List state,
  );

  /// Удаляет состояние пира. Отсутствие записи — не ошибка.
  Future<Result<void, E2eSessionStoreError>> delete(String peerId);
}

/// In-memory реализация для тестов и разработки.
///
/// Не сохраняет данные между перезапусками и хранит состояние в открытом
/// виде — не использовать в продакшене.
class MemoryE2eSessionStore implements E2eSessionStore {
  final Map<String, Uint8List> _entries = <String, Uint8List>{};

  /// Количество сохранённых сессий.
  int get length => _entries.length;

  @override
  Future<Result<Uint8List?, E2eSessionStoreError>> load(String peerId) async {
    final state = _entries[peerId];
    if (state == null) return const Ok(null);
    return Ok(Uint8List.fromList(state));
  }

  @override
  Future<Result<void, E2eSessionStoreError>> save(
    String peerId,
    Uint8List state,
  ) async {
    _entries[peerId] = Uint8List.fromList(state);
    return const Ok(null);
  }

  @override
  Future<Result<void, E2eSessionStoreError>> delete(String peerId) async {
    _entries.remove(peerId);
    return const Ok(null);
  }

  @override
  String toString() => 'MemoryE2eSessionStore(${_entries.length} сессий)';
}
