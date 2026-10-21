import 'dart:typed_data';
import 'package:meta/meta.dart';

/// Идентификатор узла в сети OpenSink — открытый ключ Ed25519.
///
/// PeerId не несёт семантики пользователя (UserId), а идентифицирует сетевой
/// узел (device). Несколько PeerId могут принадлежать одной идентичности.
@immutable
class PeerId {
  const PeerId(this.publicKey);

  /// Байты открытого ключа Ed25519 (32 байта).
  final Uint8List publicKey;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerId && runtimeType == other.runtimeType &&
          _bytesEquals(publicKey, other.publicKey);

  @override
  int get hashCode => Object.hashAll(publicKey);

  @override
  String toString() => 'PeerId(${publicKey.toList().take(8).join('')}...)';
}

bool _bytesEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Идентификатор группы.
@immutable
class GroupId {
  const GroupId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupId && runtimeType == other.runtimeType && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'GroupId($value)';
}

/// Идентификатор канала внутри группы.
@immutable
class ChannelId {
  const ChannelId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChannelId && runtimeType == other.runtimeType && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ChannelId($value)';
}

/// Идентификатор пользователя (открытый ключ Ed25519 в hex).
@immutable
class UserId {
  const UserId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserId && runtimeType == other.runtimeType && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'UserId($value)';
}

/// Идентификатор события.
@immutable
class EventId {
  const EventId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EventId && runtimeType == other.runtimeType && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'EventId($value)';
}

/// Идентификатор сообщения.
@immutable
class MessageId {
  const MessageId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageId && runtimeType == other.runtimeType && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MessageId($value)';
}
