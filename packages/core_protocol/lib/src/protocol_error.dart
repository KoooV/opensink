import 'package:core_domain/core_domain.dart';

/// Ошибки протокола OpenSink — доменные ошибки, не исключения.
/// Все операции парсинга и валидации возвращают [Result] с этими ошибками.
sealed class ProtocolError {
  const ProtocolError();

  String _toString();

  @override
  String toString() => _toString();
}

/// Ошибка декодирования wire-формата.
class DecodeError extends ProtocolError {
  const DecodeError(this.message, [this.details]);

  final String message;
  final String? details;

  @override
  String _toString() =>
      'DecodeError($message${details != null ? ': $details' : ''})';
}

/// Ошибка валидации поля/инварианта сообщения.
class ValidationError extends ProtocolError {
  const ValidationError(this.message, [this.field]);

  final String message;
  final int? field;

  @override
  String _toString() =>
      'ValidationError($message${field != null ? ' (field $field)' : ''})';
}

/// Превышен лимит размера.
class SizeLimitExceeded extends ProtocolError {
  const SizeLimitExceeded(this.actual, this.limit);

  final int actual;
  final int limit;

  @override
  String _toString() => 'SizeLimitExceeded(actual=$actual, limit=$limit)';
}

/// Версия протокола не поддерживается.
class UnknownVersion extends ProtocolError {
  const UnknownVersion(this.version);

  final int version;

  @override
  String _toString() => 'UnknownVersion($version)';
}

/// Тип сообщения не recognised (для информации; не фатально — пересылается).
class UnknownMessageType extends ProtocolError {
  const UnknownMessageType(this.type);

  final int type;

  @override
  String _toString() => 'UnknownMessageType($type)';
}

/// Подпись энвелопа неверна.
class InvalidSignature extends ProtocolError {
  const InvalidSignature();

  @override
  String _toString() => 'InvalidSignature';
}

/// Запрошенная аллокация превышает лимит.
class AllocationLimitExceeded extends ProtocolError {
  const AllocationLimitExceeded(this.requested, this.limit);

  final int requested;
  final int limit;

  @override
  String _toString() => 'AllocationLimitExceeded(requested=$requested, limit=$limit)';
}

/// Ошибка чанкования / сборки больших вложений.
class ChunkingError extends ProtocolError {
  const ChunkingError(this.message);

  final String message;

  @override
  String _toString() => 'ChunkingError($message)';
}
