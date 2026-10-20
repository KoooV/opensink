import '../models/identifiers.dart';
import '../result.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Доменная ошибка хранилища секретов.
///
/// Все варианты — доменные ошибки: отсутствие ключа не является аварийной
/// ситуацией, сбой инфраструктуры ([StoreError]) оборачивает инфраструктурное
/// исключение и не раскрывает секретов в тексте ошибки.
sealed class KeyStoreError {
  const KeyStoreError();
}

/// Ключ отсутствует в хранилище.
class IdentityNotFound extends KeyStoreError {
  const IdentityNotFound();
}

/// Сбой инфраструктурного хранилища (Keystore, libsecret, IndexedDB и т.п.).
///
/// [message] содержит понятное пользователю/оператору описание и инструкцию,
/// но не секретный материал.
class StoreError extends KeyStoreError {
  const StoreError(this.message);

  final String message;

  @override
  String toString() => 'StoreError($message)';
}

/// Хранилище секретов пользователя (закрытые ключи Ed25519, сессионные ключи).
///
/// Реализация платформенная (Keystore / libsecret / Web Crypto API) — через
/// platform_* пакеты с conditional import. В core_domain — только контракт.
///
/// Все методы возвращают [Result]: отсутствие ключа и ошибки хранилища —
/// доменные ошибки, не исключения.
abstract class SecureKeyStore {
  /// Сохраняет идентичность пользователя.
  Future<Result<void, KeyStoreError>> storeIdentity(UserId userId, IdentityBundle bundle);

  /// Загружает идентичность пользователя.
  ///
  /// Возвращает `Err(IdentityNotFound)`, если ключ отсутствует.
  Future<Result<IdentityBundle, KeyStoreError>> loadIdentity(UserId userId);

  /// Удаляет идентичность пользователя.
  Future<Result<void, KeyStoreError>> deleteIdentity(UserId userId);

  /// Проверяет наличие идентичности.
  Future<Result<bool, KeyStoreError>> hasIdentity(UserId userId);
}

/// Пакет для хранения в SecureKeyStore (секрет зашифрован ключом устройства).
@immutable
class IdentityBundle {
  const IdentityBundle({
    required this.userId,
    required this.publicKey,
    required this.encryptedPrivateKey,
    required this.createdAt,
  });

  final UserId userId;
  /// Hex Ed25519 public key.
  final String publicKey;
  /// Приватный ключ (seed). Не является самодостаточным шифртекстом:
  /// защита обеспечивается платформенным хранилищем (Keystore/libsecret),
  /// а в `MemorySecureKeyStore` хранится verbatim.
  final List<int> encryptedPrivateKey;
  final int createdAt; // Unix ms

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IdentityBundle &&
          runtimeType == other.runtimeType &&
          userId == other.userId &&
          publicKey == other.publicKey &&
          const ListEquality<int>().equals(encryptedPrivateKey, other.encryptedPrivateKey) &&
          createdAt == other.createdAt;

  @override
  int get hashCode =>
      userId.hashCode ^
      publicKey.hashCode ^
      const ListEquality<int>().hash(encryptedPrivateKey) ^
      createdAt.hashCode;

  /// Безопасное представление для логов: не раскрывает [encryptedPrivateKey].
  @override
  String toString() =>
      'IdentityBundle(userId=${userId.value}, publicKey=$publicKey, '
      'encryptedPrivateKeyLength=${encryptedPrivateKey.length}, createdAt=$createdAt)';
}
