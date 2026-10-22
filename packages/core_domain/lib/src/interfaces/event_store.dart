import '../models/identifiers.dart';
import '../result.dart';
import 'package:meta/meta.dart';

/// Результат записи события в лог.
class InsertOutcome {
  const InsertOutcome({required this.inserted, required this.duplicate});

  /// Новая строка добавлена (событие с таким id ещё не существовало).
  final bool inserted;

  /// Событие с таким id уже существовало — байты не перезаписаны (дубль).
  final bool duplicate;

  @override
  String toString() =>
      'InsertOutcome(inserted=$inserted, duplicate=$duplicate)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InsertOutcome &&
          runtimeType == other.runtimeType &&
          inserted == other.inserted &&
          duplicate == other.duplicate;

  @override
  int get hashCode => Object.hash(inserted, duplicate);
}

/// Типизированные ошибки записи события в хранилище.
sealed class EventStoreWriteError implements Exception {
  const EventStoreWriteError();
}

/// Автор события не валиден (пустой или не 32 байта в hex).
class InvalidAuthor extends EventStoreWriteError {
  const InvalidAuthor();
}

/// Идентификатор события не валиден (пустой).
class InvalidId extends EventStoreWriteError {
  const InvalidId();
}

/// Полезная нагрузка события не валидна (пустая).
class InvalidPayload extends EventStoreWriteError {
  const InvalidPayload();
}

/// Полезная нагрузка превышает допустимый размер.
class PayloadTooLarge extends EventStoreWriteError {
  const PayloadTooLarge();
}

/// Ошибка хранилища при записи (инфраструктурная).
class StorageWriteError extends EventStoreWriteError {
  const StorageWriteError();
}

/// Запись события в лог.
@immutable
class EventRecord {
  const EventRecord({
    required this.id,
    required this.groupId,
    required this.author,
    required this.payload,
    required this.timestamp,
    required this.signature,
    this.channelId,
  });

  final String id;
  final GroupId groupId;
  /// Канал внутри группы; null — событие уровня группы.
  final ChannelId? channelId;
  /// Hex-encoded 32-байтный Ed25519 публичный ключ отправителя (64 символа).
  /// Заполняется вызывающим кодом (слой 7) после проверки подписи события;
  /// хранилище не извлекает автора из непрозрачного payload.
  final String author;
  /// Сериализованное событие (protobuf / JSON). Хранилище не парсит.
  final List<int> payload;
  final int timestamp; // Unix ms
  final String signature; // hex Ed25519

  @override
  String toString() =>
      'EventRecord(id=$id, groupId=$groupId, channelId=$channelId, author=$author)';
}

/// Хранилище событий (log). Каждое событие — неизменяемая запись.
abstract class EventStore {
  /// Записывает событие.
  ///
  /// Возвращает [InsertOutcome]: `inserted = true` если новая строка добавлена,
  /// `duplicate = true` если событие с таким `id` уже существовало (байты не
  /// перезаписаны). При невалидной записи возвращает [Err] с
  /// типизированной [EventStoreWriteError], в БД ничего не пишется.
  Future<Result<InsertOutcome, EventStoreWriteError>> write(EventRecord record);

  /// Читает историю с события [cursor] включительно, затем новые записи.
  ///
  /// [cursor] — id события. Пустой или неизвестный курсор означает начало
  /// истории. Дубли по id не выдаются.
  Stream<EventRecord> watchFrom(String cursor);

  /// Вся история группы (hlc ASC), затем новые записи этой группы.
  Stream<EventRecord> watchGroup(GroupId groupId);

  /// Закрывает хранилище.
  Future<void> close();
}
