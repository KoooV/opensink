import 'package:meta/meta.dart';
import '../models/user.dart';

/// Хранилище секретов пользователя (закрытые ключи Ed25519, сессионные ключи).
/// Реализация платформенная (Keystore / libsecret / Web Crypto API) — через
/// platform_* пакеты с conditional import. В core_domain — только интерфейс.
abstract class SecureKeyStore {
  /// Сохраняет идентичность пользователя.
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle);

  /// Загружает идентичность пользователя.
  Future<IdentityBundle?> loadIdentity(UserId userId);

  /// Удаляет идентичность пользователя.
  Future<void> deleteIdentity(UserId userId);

  /// Проверяет наличие идентичности.
  Future<bool> hasIdentity(UserId userId);
}

@immutable
class IdentityBundle {
  const IdentityBundle({
    required this.userId,
    required this.publicKey,
    required this.encryptedPrivateKey, // зашифровано ключом устройства
    required this.createdAt,
  });

  final UserId userId;
  final String publicKey; // hex Ed25519 public key
  final List<int> encryptedPrivateKey;
  final int createdAt;
}
