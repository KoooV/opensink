import 'package:core_domain/core_domain.dart';

sealed class CryptoError {
  const CryptoError();
}

class InvalidSignature extends CryptoError {
  const InvalidSignature();
}

class InvalidKey extends CryptoError {
  const InvalidKey();
}

class DecryptionFailed extends CryptoError {
  const DecryptionFailed();
}

class KeyDerivationFailed extends CryptoError {
  const KeyDerivationFailed();
}

class AlreadyInitialized extends CryptoError {
  const AlreadyInitialized();
}

class EncryptionFailed extends CryptoError {
  const EncryptionFailed();
}

typedef CryptoResult<T> = Result<T, CryptoError>;

/// Личная E2E-сессия с указанным пиром не установлена.
///
/// Используется менеджером E2E-сессий для fail-closed поведения: без сессии
/// сообщение не шифруется и не отправляется.
class SessionUnavailable extends CryptoError {
  const SessionUnavailable();
}

/// Не удалось сохранить/загрузить состояние E2E-сессии.
///
/// Fail-closed: операция не возвращает шифртекст или открытый текст, пока
/// новое состояние ratchet не зафиксировано в хранилище.
class SessionPersistenceFailed extends CryptoError {
  const SessionPersistenceFailed();
}
