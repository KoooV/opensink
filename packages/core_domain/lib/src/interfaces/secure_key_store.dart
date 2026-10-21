import '../models/identifiers.dart';
import '../result.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Доменная ошибка хранилища секретов.
///
/// Все варианты — доменные ошибки: отсутствие ключа не является аварийной
/// ситуацией, сбои инфраструктуры оборачиваются в типизированные ошибки и не
/// раскрывают секретов в тексте ошибки.
sealed class KeyStoreError {
  const KeyStoreError();
}

/// Ключ отсутствует в хранилище (не является аварийной ситуацией).
class IdentityNotFound extends KeyStoreError {
  const IdentityNotFound();
}

/// Хранилище недоступно (например, Secret Service не запущен, Keystore
/// недоступен). [message] содержит инструкцию для пользователя/оператора,
/// но не секретный материал.
class StoreUnavailable extends KeyStoreError {
  const StoreUnavailable(this.message);

  final String message;

  @override
  String toString() => 'StoreUnavailable($message)';
}

/// Данные в хранилище повреждены (неверный формат, несовместимая версия
/// схемы, некорректный базовый64/JSON).
class StoreCorrupted extends KeyStoreError {
  const StoreCorrupted(this.message);

  final String message;

  @override
  String toString() => 'StoreCorrupted($message)';
}

/// Доступ к хранилищу запрещен (биометрия, блокировка экрана, права).
class StoreAccessDenied extends KeyStoreError {
  const StoreAccessDenied(this.message);

  final String message;

  @override
  String toString() => 'StoreAccessDenied($message)';
}

/// Общая инфраструктурная ошибка хранилища (неизвестная причина).
///
/// [message] содержит понятное описание и инструкцию, но не секретный
/// материал.
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

/// Пакет для хранения в SecureKeyStore.
///
/// [privateSeed] содержит приватный ключ (seed) пользователя. Он **не является
/// самодостаточным шифртекстом**: в `core_crypto` нет мастер-ключа, поэтому
/// `MemorySecureKeyStore` хранит поле verbatim. Защита обеспечивается
/// **платформенным хранилищем** (flutter_secure_storage → Keystore/libsecret),
/// которое шифрует данные при записи. Название поля отражает это: `privateSeed`,
/// а не `encryptedPrivateKey`.
@immutable
class IdentityBundle {
  const IdentityBundle({
    required this.userId,
    required this.publicKey,
    required this.privateSeed,
    required this.createdAt,
  });

  final UserId userId;
  /// Hex Ed25519 public key.
  final String publicKey;
  /// Приватный ключ (seed). Защита обеспечивается платформенным хранилищем,
  /// а не шифрованием на уровне приложения.
  final List<int> privateSeed;
  final int createdAt; // Unix ms

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IdentityBundle &&
          runtimeType == other.runtimeType &&
          userId == other.userId &&
          publicKey == other.publicKey &&
          const ListEquality<int>().equals(privateSeed, other.privateSeed) &&
          createdAt == other.createdAt;

  @override
  int get hashCode =>
      userId.hashCode ^
      publicKey.hashCode ^
      const ListEquality<int>().hash(privateSeed) ^
      createdAt.hashCode;

  /// Безопасное представление для логов: не раскрывает [privateSeed].
  @override
  String toString() =>
      'IdentityBundle(userId=${userId.value}, publicKey=$publicKey, '
      'privateSeedLength=${privateSeed.length}, createdAt=$createdAt)';
}
