import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';

/// Доменные ошибки хранилища `GroupSecret`.
sealed class GroupSecretError {
  const GroupSecretError();

  @override
  String toString() => runtimeType.toString();
}

/// Инфраструктурная ошибка хранилища.
class GroupSecretStorageFailure extends GroupSecretError {
  const GroupSecretStorageFailure(this.reason);

  final String reason;

  @override
  String toString() => 'GroupSecretStorageFailure($reason)';
}

/// Сохранённый секрет повреждён или имеет неверную длину.
class CorruptedGroupSecret extends GroupSecretError {
  const CorruptedGroupSecret(this.reason);

  final String reason;

  @override
  String toString() => 'CorruptedGroupSecret($reason)';
}

/// Персистентное хранилище секрета группы.
///
/// Секрет — членство и ключ signaling; реализация обязана хранить его только
/// в защищённом хранилище платформы. `load` возвращает `Ok(null)`, если секрета
/// нет.
abstract class GroupSecretStore {
  Future<Result<void, GroupSecretError>> save(
    GroupId groupId,
    List<int> secret,
  );

  Future<Result<List<int>?, GroupSecretError>> load(GroupId groupId);

  Future<Result<void, GroupSecretError>> delete(GroupId groupId);
}

/// In-memory реализация для тестов.
class MemoryGroupSecretStore implements GroupSecretStore {
  final Map<String, List<int>> _secrets = <String, List<int>>{};

  @override
  Future<Result<void, GroupSecretError>> save(
    GroupId groupId,
    List<int> secret,
  ) async {
    if (secret.length != 32) {
      return const Err(CorruptedGroupSecret('secret is not 32 bytes'));
    }
    _secrets[groupId.value] = List<int>.unmodifiable(secret);
    return const Ok(null);
  }

  @override
  Future<Result<List<int>?, GroupSecretError>> load(GroupId groupId) async {
    final secret = _secrets[groupId.value];
    return Ok(secret == null ? null : List<int>.of(secret));
  }

  @override
  Future<Result<void, GroupSecretError>> delete(GroupId groupId) async {
    _secrets.remove(groupId.value);
    return const Ok(null);
  }
}

/// Кодирует секрет для инвайт-ссылки: 64 hex-символа.
String encodeGroupSecretToken(List<int> secret) {
  if (secret.length != 32) {
    throw ArgumentError.value(secret.length, 'secret', 'must be 32 bytes');
  }
  final buffer = StringBuffer();
  for (final byte in secret) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Разбирает секрет из инвайт-ссылки. Посторонние форматы отклоняются.
Uint8List? decodeGroupSecretToken(String token) {
  if (token.length != 64) return null;
  final result = Uint8List(32);
  for (var i = 0; i < result.length; i++) {
    final high = _hexNibble(token.codeUnitAt(i * 2));
    final low = _hexNibble(token.codeUnitAt(i * 2 + 1));
    if (high < 0 || low < 0) return null;
    result[i] = high * 16 + low;
  }
  return result;
}

int _hexNibble(int code) {
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
  return -1;
}
