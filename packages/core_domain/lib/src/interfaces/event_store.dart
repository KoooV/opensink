import 'package:meta/meta.dart';

/// Хранилище событий (log). Каждое событие — неизменяемая запись.
abstract class EventStore {
  /// Записывает событие.
  Future<void> write(EventRecord record);

  /// Читает события после (включительно) заданного курсора.
  Stream<EventRecord> watchFrom(String cursor);

  /// Все события группы.
  Stream<EventRecord> watchGroup(GroupId groupId);

  Future<void> close();
}

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
  final List<int> payload; // сериализованное событие
  final int timestamp;
  final String signature;
}
