/// Тип сообщения OpenSink.
///
/// Реализован как класс с числовым значением, чтобы незнакомые типы
/// (от более новых версий протокола) можно было пересылать дальше,
/// не теряя информации.
class MessageType {
  const MessageType._(this.value);

  final int value;

  /// Тип известен текущей версией протокола.
  bool get isKnown => value >= 1 && value <= 10;

  static const unknown = MessageType._(0);
  static const chatEvent = MessageType._(1);
  static const groupEvent = MessageType._(2);
  static const syncRequest = MessageType._(3);
  static const syncResponse = MessageType._(4);
  static const fileChunk = MessageType._(5);
  static const fileRequest = MessageType._(6);
  static const presence = MessageType._(7);
  static const callControl = MessageType._(8);
  static const relayFrame = MessageType._(9);
  static const leaderLease = MessageType._(10);

  static MessageType fromInt(int value) {
    switch (value) {
      case 0:
        return unknown;
      case 1:
        return chatEvent;
      case 2:
        return groupEvent;
      case 3:
        return syncRequest;
      case 4:
        return syncResponse;
      case 5:
        return fileChunk;
      case 6:
        return fileRequest;
      case 7:
        return presence;
      case 8:
        return callControl;
      case 9:
        return relayFrame;
      case 10:
        return leaderLease;
      default:
        return MessageType._(value);
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageType && runtimeType == other.runtimeType && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    final name = switch (value) {
      0 => 'UNKNOWN',
      1 => 'CHAT_EVENT',
      2 => 'GROUP_EVENT',
      3 => 'SYNC_REQUEST',
      4 => 'SYNC_RESPONSE',
      5 => 'FILE_CHUNK',
      6 => 'FILE_REQUEST',
      7 => 'PRESENCE',
      8 => 'CALL_CONTROL',
      9 => 'RELAY_FRAME',
      10 => 'LEADER_LEASE',
      _ => 'TYPE($value)',
    };
    return 'MessageType($name)';
  }
}
