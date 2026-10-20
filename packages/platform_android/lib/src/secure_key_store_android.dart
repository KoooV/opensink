import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:core_domain/core_domain.dart';

/// SecureKeyStore для Android (Keystore) через flutter_secure_storage (v9.2.4).
///
/// Закрытый ключ хранится в зашифрованном виде на уровне платформенного
/// хранилища (Keystore / StrongBox, когда доступен). flutter_secure_storage
/// отвечает за шифрование при записи и расшифровку при чтении.
///
/// Гарантии (см. DESIGN.md §2):
/// - Дамп файловой системы и доступ из других приложений не раскрывают секрет.
/// - Не защищает от root; StrongBox не гарантирован на всех устройствах;
///   ключи не восстанавливаются при переносе на новое устройство.
/// - При сбое хранилища возвращается [StoreError] с понятным сообщением;
///   никакого тихого отката на файл в открытом виде.
class NativeSecureKeyStoreImpl implements SecureKeyStore {
  NativeSecureKeyStoreImpl({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kPrefix = 'opensink_identity_';

  String _key(UserId userId) => '${_kPrefix}${userId.value}';

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
      return Err(StoreError('Не удалось сохранить идентичность в Keystore: $e\n$stack'));
    }
  }

  @override
  Future<Result<IdentityBundle, KeyStoreError>> loadIdentity(UserId userId) async {
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
      return Err(StoreError('Не удалось загрузить идентичность из Keystore: $e\n$stack'));
    }
  }

  @override
  Future<Result<void, KeyStoreError>> deleteIdentity(UserId userId) async {
    try {
      await _storage.delete(key: _key(userId));
      return const Ok(null);
    } catch (e, stack) {
      return Err(StoreError('Не удалось удалить идентичность из Keystore: $e\n$stack'));
    }
  }

  @override
  Future<Result<bool, KeyStoreError>> hasIdentity(UserId userId) async {
    try {
      final value = await _storage.read(key: _key(userId));
      return Ok(value != null && value.isNotEmpty);
    } catch (e, stack) {
      return Err(StoreError('Не удалось проверить наличие идентичности в Keystore: $e\n$stack'));
    }
  }
}
