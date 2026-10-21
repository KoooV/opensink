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
