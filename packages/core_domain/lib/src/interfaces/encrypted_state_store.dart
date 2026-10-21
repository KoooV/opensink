import 'dart:typed_data';

import '../result.dart';

/// Доменная ошибка хранилища запечатанных состояний.
sealed class EncryptedStateStoreError {
  const EncryptedStateStoreError();
}

/// Состояние не найдено (не является аварийной ситуацией).
class StateNotFound extends EncryptedStateStoreError {
  const StateNotFound();
}

/// Хранилище недоступно (сбой инфраструктуры). [message] не содержит секретов.
class StoreUnavailable extends EncryptedStateStoreError {
  const StoreUnavailable(this.message);

  final String message;

  @override
  String toString() => 'StoreUnavailable($message)';
}

/// Данные в хранилище повреждены (неверный формат, версия схемы).
class StoreCorrupted extends EncryptedStateStoreError {
  const StoreCorrupted(this.message);

  final String message;

  @override
  String toString() => 'StoreCorrupted($message)';
}

/// Общая инфраструктурная ошибка хранилища.
class StoreError extends EncryptedStateStoreError {
  const StoreError(this.message);

  final String message;

  @override
  String toString() => 'StoreError($message)';
}

/// Хранилище запечатанных (sealed) состояний E2EE.
///
/// Реализация в `core_storage` (drift: SQLite / OPFS) — вне этой фазы.
/// Контракт для слоёв 4 и 7: состояние ratchet и принятое событие
/// сохраняются в **одной транзакции** хранилища.
///
/// Политика при сбое между расшифровкой и записью:
/// - если состояние расшифровано, но запись в хранилище не удалась —
///   ключ сообщения считается потерянным; повтор того же сообщения не
///   расшифруется (follows from ratchet chain-key advancement);
/// - приложение должно logarithмировать сбой без раскрытия ключей и
///   предложить пользователю повторную синхронизацию сессии.
abstract class EncryptedStateStore {
  /// Загружает запечатанное состояние по [id].
  ///
  /// Возвращает `Err(StateNotFound)`, если состояние отсутствует.
  Future<Result<Uint8List, EncryptedStateStoreError>> load(String id);

  /// Сохраняет [sealed] состояние по [id].
  Future<Result<void, EncryptedStateStoreError>> save(String id, Uint8List sealed);
}
