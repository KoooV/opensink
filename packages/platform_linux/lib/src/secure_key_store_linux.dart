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
/// - При отсутствии Secret Service возвращается [StoreUnavailable] с
///   инструкцией; никакого тихого отката на файл в открытом виде.
class LinuxSecureKeyStoreImpl implements SecureKeyStore {
  LinuxSecureKeyStoreImpl({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// Версия схемы сериализации IdentityBundle.
  static const int _schemaVersion = 1;
  static const _kPrefix = 'opensink_identity_v${_schemaVersion}_';

  static const _secretServiceUnavailableInstruction =
      'Secret Service (libsecret) недоступен. Установите libsecret '
      '(например, `sudo apt-get install libsecret-1-dev`), убедитесь, что '
      'рабочий стол и ключ-ринг запущены и разблокированы, а переменная '
      'DBUS_SESSION_BUS_ADDRESS определена.';

  /// Проверяет наличие зависимостей libsecret при инициализации.
  ///
  /// Возвращает `Err(StoreUnavailable)`, если Secret Service недоступен,
  /// с понятной инструкцией. Никакого тихого отката на файл в открытом виде.
  Future<Result<void, KeyStoreError>> checkDependencies() async {
    try {
      final value = await _storage.read(key: '_opensink_probe_');
      // Простая операция записи/чтения достаточно для проверки доступности.
      await _storage.write(key: '_opensink_probe_', value: 'probe');
      await _storage.delete(key: '_opensink_probe_');
      return const Ok(null);
    } catch (e, stack) {
      final message = e.toString().toLowerCase();
      if (message.contains('unavailable') ||
          message.contains('not available') ||
          message.contains('secret service') ||
          message.contains('dbus') ||
          message.contains('session bus')) {
        return Err(StoreUnavailable(
          '$_secretServiceUnavailableInstruction\n$stack',
        ));
      }
      return Err(StoreUnavailable(
        'Не удалось инициализировать libsecret: $e\n$_secretServiceUnavailableInstruction\n$stack',
      ));
    }
  }

  String _key(UserId userId) => '${_kPrefix}${userId.value}';

  Map<String, dynamic> _serialize(IdentityBundle bundle) => <String, dynamic>{
        'userId': bundle.userId.value,
        'publicKey': bundle.publicKey,
        'privateSeed': base64Encode(bundle.privateSeed),
        'createdAt': bundle.createdAt,
        'schemaVersion': _schemaVersion,
      };

  IdentityBundle _deserialize(Map<String, dynamic> map) {
    final version = map['schemaVersion'] as int?;
    if (version == null || version != _schemaVersion) {
      throw FormatException('Неподдерживаемая версия схемы: $version');
    }
    final seedBase64 = map['privateSeed'] as String?;
    if (seedBase64 == null) {
      throw FormatException('Отсутствует privateSeed в записи хранилища');
    }
    return IdentityBundle(
      userId: UserId(map['userId'] as String),
      publicKey: map['publicKey'] as String,
      privateSeed: base64Decode(seedBase64),
      createdAt: map['createdAt'] as int,
    );
  }

  static KeyStoreError _mapError(Object e, StackTrace stack, String operation) {
    final message = e.toString();
    final lower = message.toLowerCase();
    if (lower.contains('unavailable') ||
        lower.contains('not available') ||
        lower.contains('secret service') ||
        lower.contains('dbus') ||
        lower.contains('session bus')) {
      return StoreUnavailable(
        'Хранилище libsecret недоступен при $operation: $message\n'
        '$_secretServiceUnavailableInstruction\n$stack',
      );
    }
    if (lower.contains('access denied') || lower.contains('permission')) {
      return StoreAccessDenied(
        'Доступ к libsecret запрещен при $operation: $message\n$stack',
      );
    }
    if (lower.contains('corrupt') || lower.contains('invalid') || lower.contains('format')) {
      return StoreCorrupted(
        'Данные в libsecret повреждены при $operation: $message\n$stack',
      );
    }
    return StoreError(
      'Не удалось $operation в libsecret: $message\n'
      '$_secretServiceUnavailableInstruction\n$stack',
    );
  }

  @override
  Future<Result<void, KeyStoreError>> storeIdentity(
    UserId userId,
    IdentityBundle bundle,
  ) async {
    try {
      await _storage.write(
        key: _key(userId),
        value: jsonEncode(_serialize(bundle)),
      );
      return const Ok(null);
    } catch (e, stack) {
      return Err(_mapError(e, stack, 'сохранение идентичности'));
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
      return Ok(_deserialize(map));
    } on FormatException catch (e, stack) {
      return Err(StoreCorrupted('Повреждённые данные в libsecret: $e\n$stack'));
    } catch (e, stack) {
      return Err(_mapError(e, stack, 'загрузка идентичности'));
    }
  }

  @override
  Future<Result<void, KeyStoreError>> deleteIdentity(UserId userId) async {
    try {
      await _storage.delete(key: _key(userId));
      return const Ok(null);
    } catch (e, stack) {
      return Err(_mapError(e, stack, 'удаление идентичности'));
    }
  }

  @override
  Future<Result<bool, KeyStoreError>> hasIdentity(UserId userId) async {
    try {
      final value = await _storage.read(key: _key(userId));
      return Ok(value != null && value.isNotEmpty);
    } catch (e, stack) {
      return Err(_mapError(e, stack, 'проверка наличия идентичности'));
    }
  }

  @override
  Future<Result<void, KeyStoreError>> storeKey(
    String keyId,
    List<int> bytes,
  ) async {
    try {
      await _storage.write(
        key: _stateKey(keyId),
        value: base64Encode(bytes),
      );
      return const Ok(null);
    } catch (e, stack) {
      return Err(_mapError(e, stack, 'сохранение ключа состояния'));
    }
  }

  @override
  Future<Result<List<int>, KeyStoreError>> loadKey(String keyId) async {
    try {
      final value = await _storage.read(key: _stateKey(keyId));
      if (value == null) {
        return const Err(IdentityNotFound());
      }
      return Ok(base64Decode(value));
    } on FormatException catch (e, stack) {
      return Err(
        StoreCorrupted('Повреждённые данные ключа состояния: $e\n$stack'),
      );
    } catch (e, stack) {
      return Err(_mapError(e, stack, 'загрузка ключа состояния'));
    }
  }

  @override
  Future<Result<void, KeyStoreError>> deleteKey(String keyId) async {
    try {
      await _storage.delete(key: _stateKey(keyId));
      return const Ok(null);
    } catch (e, stack) {
      return Err(_mapError(e, stack, 'удаление ключа состояния'));
    }
  }
}
