import '../models/identifiers.dart';

/// Запись события в логе.
@immutable
class EventRecord {
  const EventRecord({
    required this.id,
    required this.groupId,
    required this.payload,
    required this.timestamp,
    required this.signature,
  });

  final String id;
  final GroupId groupId;
  /// Сериализованное событие (protobuf / JSON).
  final List<int> payload;
  final int timestamp; // Unix ms
  final String signature; // hex Ed25519

  @override
  String toString() => 'EventRecord(id=$id, groupId=$groupId)';
}

/// Хранилище событий (log). Каждое событие — неизменяемая запись.
abstract class EventStore {
  /// Записывает событие.
  Future<void> write(EventRecord record);

  /// Читает события после (включительно) заданного курсора.
  Stream<EventRecord> watchFrom(String cursor);

  /// Все события группы.
  Stream<EventRecord> watchGroup(GroupId groupId);

  /// Закрывает хранилище.
  Future<void> close();
}
