# Приёмка core_sync (слой синхронизации)

## AC1 — HLC и id события

- `Hlc` = `(physicalMs, counter)`, монотонный `tick`, `observe` обгоняет remote.
- `id = SHA-256(domain || canonical)`, canonical включает `prevId`.
- Тесты: `test/hlc_test.dart`, `test/sync_event_test.dart`.

## AC2 — конвейер приёма

Порядок `размер → id → подпись → членство → дедуп → запись` покрыт
`test/ingest_pipeline_test.dart`: oversize, id mismatch, bad signature,
member at event time, unknown author pending, duplicate.

## AC3 — anti-entropy и backpressure

- Сводки по фиксированным HLC-бакетам (60 с), `RangeRequest`/`EventsFrame` с курсором.
- Автоматически догружается самый свежий расходящийся диапазон; старая история —
  по явному `requestHistory` (UI).
- Не более одной следующей страницы на диапазон после применения текущей.
- Тесты: `test/anti_entropy_test.dart` (раздел сети, 100% потерь).

## AC4 — gossip и штормы

- Дедуп по id, `hops ≤ 4`, LRU отправленных, token bucket.
- Тесты: `test/gossip_test.dart` (доставка всем, отсутствие амплификации,
  повторный anti-entropy не создаёт дублей).

## AC5 — приоритетная загрузка

- `WindowRequest` уходит раньше `SummaryFrame`.
- `channelWindow(limit: N)` возвращает последние N сообщений.
- Тесты: `test/priority_loading_test.dart`.

## AC6 — tombstones

- Права: только автор сообщения.
- Правка/удаление — отдельные события, оригинал не мутируется.
- Чужая правка игнорируется проекцией.
- Тесты: `test/tombstone_test.dart`.

## AC7 — сходимость

`test/convergence_sim_test.dart` — **1000 прогонов** с seed, N=3, реальный
Ed25519, случайный порядок доставки, случайные потери и разделы сети. После лечения сети все
реплики имеют одинаковый набор id событий и одинаковую проекцию состояния.
Результат: **1000/1000 без расхождений** (VM, реальный Ed25519, ~6.5 мин).

## AC8 — платформенная чистота и анализ

- `core_sync` не импортирует `dart:io`/`dart:html`/`package:web`.
- `dart analyze packages/core_sync` — No issues.

## AC9 — e2e поверх DriftEventStore

`packages/core_sync/test/drift_e2e_test.dart` использует реальный
`DriftEventStore` (не `MemorySyncEventStore`):

1. две реплики сходятся через gossip/anti-entropy, затем состояние
   восстанавливается после пересоздания `SyncEngineImpl` на том же store;
2. channel-scoped `requestHistory` передаёт `channelId` по wire-протоколу и
   возвращает только события выбранного канала;
3. pending-событие переживает рестарт движка, лежит в `pending_events` и
   применяется после получения membership-события.

## AC10 — Chrome/dart2js

`bash tool/test_web_sync_chrome.sh` прогоняет `drift_e2e_test.dart` и
`core_protocol/test/wire_test.dart` в Chrome с `-c dart2js`. CI job
`core_sync-web` использует тот же скрипт.
Прогон выявил 32-битное усечение varint в `core_protocol`; `ProtoReader` /
`ProtoWriter` переведены на арифметику, регрессия закреплена
`core_protocol/test/wire_test.dart`.

## AC11 — channel-scoped requestHistory

`SyncEngineImpl.requestHistory(groupId, channelId: ...)` ограничивает
`RangeRequestFrame` (поле 9), `SyncEventStore.eventsInRange` и последующие
страницы одним каналом. Групповой режим без `channelId` сохранён.

## AC12 — персистентность pending

Схема `core_storage` v7 добавляет `pending_events` и
`idx_pending_events_group_hlc`. `SyncEngineImpl` пишет pending до добавления
в LRU, удаляет после успешного применения/eviction и восстанавливает очередь
при `_loadGroup`. Anti-entropy остаётся резервным механизмом.

## Итоговые проверки

- `cd packages/core_sync && dart test` — **36/36** (включая 1000 seeded-прогонов).
- `bash tool/test_web_sync_chrome.sh` — **3/3 e2e + 2/2 wire** в Chrome/dart2js.
- `cd packages/core_storage && dart test` — все тесты зелёные, схема v7.
- `bash tool/test_web_storage_chrome.sh` — все тесты зелёные.
