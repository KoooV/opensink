import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:core_domain/core_domain.dart';

/// SecureKeyStore для Android (Keystore) и Linux (libsecret) через
/// flutter_secure_storage.
///
/// Закрытый ключ хранится в зашифрованном виде (IdentityBundle.encryptedPrivateKey).
/// flutter_secure_storage отвечает за шифрование на уровне хранилища устройства.
///
/// Гарантии (см. DESIGN.md):
/// - Android: Keystore / StrongBox, защита от других приложений, не защищает от root.
/// - Linux: libsecret, защита от других пользователей, не защищает от root / того же пользователя.
class NativeSecureKeyStoreImpl implements SecureKeyStore {
  NativeSecureKeyStoreImpl({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kPrefix = 'opensink_identity_';

  String _key(UserId userId) => '${_kPrefix}${userId.value}';

  @override
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle) async {
    await _storage.write(
      key: _key(userId),
      value: jsonEncode({
        'userId': bundle.userId.value,
        'publicKey': bundle.publicKey,
        'encryptedPrivateKey': base64Encode(bundle.encryptedPrivateKey),
        'createdAt': bundle.createdAt,
      }),
    );
  }

  @override
  Future<IdentityBundle?> loadIdentity(UserId userId) async {
    final json = await _storage.read(key: _key(userId));
    if (json == null) return null;
    final map = jsonDecode(json) as Map<String, dynamic>;
    return IdentityBundle(
      userId: UserId(map['userId'] as String),
      publicKey: map['publicKey'] as String,
      encryptedPrivateKey: base64Decode(map['encryptedPrivateKey'] as String),
      createdAt: map['createdAt'] as int,
    );
  }

  @override
  Future<void> deleteIdentity(UserId userId) async {
    await _storage.delete(key: _key(userId));
  }

  @override
  Future<bool> hasIdentity(UserId userId) async {
    final value = await _storage.read(key: _key(userId));
    return value != null && value.isNotEmpty;
  }
}
