import '../models/identifiers.dart';
import 'event_store.dart';

/// Расширенное хранилище событий, необходимое слою синхронизации.
///
/// [EventStore] намеренно минимален (append-only + watch). Anti-entropy
/// нужны диапазонные выборки и быстрый доступ к последним сообщениям
/// канала, поэтому слой хранения реализует этот контракт отдельно.
abstract class SyncEventStore implements EventStore {
  /// Все события группы в порядке `(hlc ASC, id ASC)`.
  Future<List<EventRecord>> groupEvents(
    GroupId groupId, {
    int? limit,
    int? offset,
  });

  /// События группы в диапазоне `[hlcFrom, hlcTo]` включительно.
  ///
  /// [channelId] ограничивает выборку событиями канала; `null` — вся группа
  /// (включая события уровня группы и других каналов).
  /// [afterHlc]/[afterId] задают курсор для пагинации: возвращаются
  /// только события строго после `(afterHlc, afterId)`.
  Future<List<EventRecord>> eventsInRange(
    GroupId groupId, {
    required int hlcFrom,
    required int hlcTo,
    int limit = 256,
    int? afterHlc,
    String? afterId,
    ChannelId? channelId,
  });

  /// Отложенные события группы, ожидающие появления membership-событий.
  ///
  /// Очередь ограничена вызывающим слоем; хранилище возвращает старые
  /// записи первыми, чтобы eviction был детерминированным.
  Future<List<EventRecord>> pendingEvents(GroupId groupId, {int limit = 256});

  /// Сохраняет отложенное событие (idempotent upsert по id).
  Future<void> putPendingEvent(EventRecord record);

  /// Удаляет отложенное событие после успешного применения.
  Future<void> deletePendingEvent(String id);

  /// Последние события канала (в порядке убывания HLC) для приоритетной
  /// загрузки. Слой синхронизации сам фильтрует типы событий.
  Future<List<EventRecord>> latestChannelEvents(
    GroupId groupId,
    ChannelId channelId, {
    int limit = 50,
  });

  /// Одно событие по id (для дедупликации и проверки цепочки).
  Future<EventRecord?> eventById(String id);
}
