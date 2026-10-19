import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';

/// Ошибки криптографического слоя core_crypto.
///
/// Все ошибки бизнес-логики (валидация подписи, неверный ключ, неверный MAC и т.п.)
/// представляются как [CryptoError]. Непредвиденные инфраструктурные ошибки
/// (ошибка PlatformException, сбой IndexedDB и т.п.) — это исключения.
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

class IdentityNotFound extends CryptoError {
  const IdentityNotFound();
}

class AlreadyInitialized extends CryptoError {
  const AlreadyInitialized();
}

/// Результат криптографической операции с типами ошибок домена.
typedef CryptoResult<T> = Result<T, CryptoError>;
