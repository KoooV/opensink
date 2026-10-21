import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:core_domain/core_domain.dart';

/// SecureKeyStore для Linux через flutter_secure_storage (libsecret /
/// secret-service, v9.2.4 + flutter_secure_storage_linux v1.2.3).
///
/// Закрытый ключ хранится в зашифрованном виде на уровне платформенного
/// хранилища (сеансовый демон libsecret, зашифровано паролем сеанса).
///
/// Гарантии (см. DESIGN.md §2):
/// - Доступ из-под других пользователей не раскрывает секрет.
/// - Не защищает от root и от того же пользователя; нет TEE;
///   зависит от наличия рабочего стола и разблокированного ключ-ринга.
/// - При отсутствии Secret Service возвращается [StoreError] с инструкцией;
///   никакого тихого отката на файл в открытом виде.
class LinuxSecureKeyStoreImpl implements SecureKeyStore {
  LinuxSecureKeyStoreImpl({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kPrefix = 'opensink_identity_';

  String _key(UserId userId) => '${_kPrefix}${userId.value}';

  static const _secretServiceUnavailableInstruction =
    'Secret Service (libsecret) недоступен. Установите libsecret '
    '(например, `sudo apt-get install libsecret-1-dev`), убедитесь, что '
    'рабочий стол и ключ-ринг запущены и разблокированы, а переменная '
    'DBUS_SESSION_BUS_ADDRESS определена.';

  @override
  Future<Result<void, KeyStoreError>> storeIdentity(
    UserId userId,
    IdentityBundle bundle,
  ) async {
    try {
      await _storage.write(
        key: _key(userId),
        value: jsonEncode({
          'userId': bundle.userId.value,
          'publicKey': bundle.publicKey,
          'encryptedPrivateKey': base64Encode(bundle.encryptedPrivateKey),
          'createdAt': bundle.createdAt,
        }),
      );
      return const Ok(null);
    } catch (e, stack) {
      return Err(
        StoreError(
          'Не удалось сохранить идентичность в libsecret: $e\n'
          '$_secretServiceUnavailableInstruction\n$stack',
        ),
      );
    }
  }

  @override
  Future<Result<IdentityBundle, KeyStoreError>> loadIdentity(
    UserId userId,
  ) async {
    try {
      final json = await _storage.read(key: _key(userId));
      if (json == null) {
        return const Err(IdentityNotFound());
      }
      final map = jsonDecode(json) as Map<String, dynamic>;
      return Ok(
        IdentityBundle(
          userId: UserId(map['userId'] as String),
          publicKey: map['publicKey'] as String,
          encryptedPrivateKey: base64Decode(map['encryptedPrivateKey'] as String),
          createdAt: map['createdAt'] as int,
        ),
      );
    } catch (e, stack) {
      return Err(
        StoreError(
          'Не удалось загрузить идентичность из libsecret: $e\n'
          '$_secretServiceUnavailableInstruction\n$stack',
        ),
      );
    }
  }

  @override
  Future<Result<void, KeyStoreError>> deleteIdentity(UserId userId) async {
    try {
      await _storage.delete(key: _key(userId));
      return const Ok(null);
    } catch (e, stack) {
      return Err(
        StoreError(
          'Не удалось удалить идентичность из libsecret: $e\n'
          '$_secretServiceUnavailableInstruction\n$stack',
        ),
      );
    }
  }

  @override
  Future<Result<bool, KeyStoreError>> hasIdentity(UserId userId) async {
    try {
      final value = await _storage.read(key: _key(userId));
      return Ok(value != null && value.isNotEmpty);
    } catch (e, stack) {
      return Err(
        StoreError(
          'Не удалось проверить наличие идентичности в libsecret: $e\n'
          '$_secretServiceUnavailableInstruction\n$stack',
        ),
      );
    }
  }
}
