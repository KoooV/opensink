# Design doc: core_storage — drift event store

Статус: документ соответствует текущему коду. Источник фактов —
`packages/core_storage/lib`, платформенные фабрики `packages/platform_*` и
`pubspec.lock` (закреплены `drift` 2.31.0, `sqlite3` 2.9.4,
`sqlite3_flutter_libs` 0.5.41).

## 1. Границы пакетов

`core_storage` — чистый Dart. Разрешённая зависимость уровня drift — только `package:drift/drift.dart`; также используются `core_domain` (модели и контракты), `package:crypto` (SHA-256 для range summary) и `package:meta` (`@internal`). В `core_storage/lib` запрещены `package:drift/native.dart`, `package:drift/wasm.dart`, `dart:io`, `dart:ffi`, `dart:html`, `package:web`, `dart:js_interop`, `sqlite3_flutter_libs`, `path_provider`.

Открытие платформенного подключения выполняют пакеты:

| Пакет | Реализация | Ресурс SQLite |
|-------|------------|---------------|
| `platform_android` | `AndroidDatabaseFactory implements StorageBackend` | bundled SQLite из `sqlite3_flutter_libs` 0.5.41 |
| `platform_linux` | `LinuxDatabaseFactory implements StorageBackend` | bundled SQLite из `sqlite3_flutter_libs` 0.5.41 либо системная `libsqlite3.so` вне Flutter-сборки |
| `platform_web` | `WebDatabaseFactory implements StorageBackend` | `sqlite3.wasm` + `drift_worker.js` |

`core_storage` экспортирует `AppDatabase`, `DriftEventStore`, `DriftBlobStore`, `RetentionPolicy`, схему, `EventData`, `RangeSummary`, `RangeSummaryError`, `StorageSpec`, `StorageInfo`, `OpenedStorage`, `StorageBackend`, `StorageOpenError`, расширение `StorageBackendResult.openResult`. Типы `Result`, `InsertOutcome` и `EventStoreWriteError` приходят из `core_domain`; `core_storage` их не реэкспортирует. Неиспользуемый `DatabaseFactory` удалён из публичного API; единственный контракт открытия — `StorageBackend`.

## 2. Контракт открытия хранилища

```dart
class StorageSpec {
  final String name;      // имя файла/БД; для memory игнорируется
  final bool inMemory;
}

class StorageInfo {
  final String backend;         // 'file' | 'opfs' | 'indexedDb' | 'memory'
  final bool isPersistent;
  final String? sqliteVersion;
  final List<String> warnings;  // неизменяемый список
}

class OpenedStorage {
  final QueryExecutor executor;
  final StorageInfo info;
}

abstract interface class StorageBackend {
  Future<OpenedStorage> open(StorageSpec spec);
}
```

`StorageBackend.open` при неустранимом сбое бросает `StorageOpenError` (sealed): `UnsupportedBackend`, `DatabaseVersionTooLow(required, actual)`, `ResourceMissing(resource)`, `OpenFailure(cause, stack)`. Для границ, которым запрещено выпускать исключения, добавлено расширение `openResult(spec) -> Result<OpenedStorage, StorageOpenError>`: известные ошибки сохраняются, неизвестные оборачиваются в `OpenFailure`.

Порядок открытия у всех фабрик одинаков: создать executor, вызвать `AppDatabase(executor).open(backend: ..., isPersistent: ..., warnings: ...)`, вернуть executor и `StorageInfo`. `AppDatabase.open` проверяет SQLite и инициализирует/мигрирует схему до возврата `StorageInfo`. При ошибке фабрика закрывает уже созданный executor и возвращает типизированную ошибку.

**Правило деградации.** Тихий откат на память с потерей данных запрещён. Режим памяти включается только явным `StorageSpec(inMemory: true)`, получает `isPersistent: false` и предупреждение в `StorageInfo.warnings`. На web Drift может сам выбрать memory при отсутствии persistence API; фабрика в этом случае возвращает `backend = 'memory'`, `isPersistent = false` и предупреждение. Отсутствующий или неверно отданный ресурс — `ResourceMissing`, а не memory.

## 3. EventRecord: кто создаёт и что проверяет хранилище

`EventRecord` (`core_domain`) содержит обязательные `id`, `groupId`, `author`, `payload`, `timestamp`, `signature` и опциональный `channelId`. `author` — hex-строка 32-байтного Ed25519 публичного ключа (64 hex-символа). Автора передаёт вызывающий слой после проверки события; `author` не извлекается из payload. `channelId == null` означает событие уровня группы.

`DriftEventStore.write` проверяет только форму:

| Поле | Проверка | Ошибка |
|------|----------|--------|
| `id` | ASCII `[A-Za-z0-9._:-]`, длина 1–128 | `InvalidId` |
| `author` | не пустой, ровно 64 hex-символа, декодируется в 32 байта | `InvalidAuthor` |
| `payload` | не пустой и не больше 1 МиБ | `InvalidPayload` / `PayloadTooLarge` |
| инфраструктура | ошибка executor-а | `StorageWriteError` |

Подпись не проверяется, payload не разбирается. Проверка формы выполняется до записи; при ошибке в БД ничего не пишется.

`write` возвращает `Result<InsertOutcome, EventStoreWriteError>`. `InsertOutcome` содержит `inserted` и `duplicate`. Вставка идёт через `INSERT OR IGNORE INTO events`; для получения числа затронутых строк используется `QueryExecutor.runUpdate` (в native и WASM executor-ах возвращает `updatedRows`). `affected == 1` → `inserted`, `affected == 0` → `duplicate`; исходные байты никогда не перезаписываются. `timestamp` записывается в колонку `hlc`.

`SyncEventStore` дополнительно отдаёт `eventsInRange(..., channelId)` (фильтр по каналу для channel-scoped `requestHistory`) и очередь `pendingEvents`/`putPendingEvent`/`deletePendingEvent`. Pending-события прошли проверку размера, id и подписи, но ещё не получили membership; они лежат отдельно от append-only лога и переживают рестарт движка. Порядок выдачи — `hlc ASC, id ASC`; повторный `put` по тому же id идемпотентен.

`RangeSummary` строится по SHA-256 от `ids.join('|')` в UTF-8. Если событий больше `limit` (по умолчанию 100000), возвращается `Err(RangeTooLarge(limit))`, усечённый digest не выдаётся. Выборка id идёт в порядке `hlc ASC, id ASC`, поэтому одинаковый набор событий даёт одинаковый digest независимо от физического порядка строк.

`channelPage` возвращает страницу канала в порядке `hlc DESC, id DESC`. `hasMore` определяется выборкой `pageSize + 1` строки, поэтому последняя полная страница не выдаёт ложный `hasMore`; `nextPage` возвращает номер следующей страницы или `null`. Пагинация остаётся offset-based; ключевой набор `(hlc, id)` детерминирован.

`watchFrom(cursor)` отдаёт историю с события `cursor` включительно (`hlc ASC, id ASC`), затем live-записи; пустой/неизвестный курсор означает начало истории. Курсор сравнивается составным ключом `(hlc, id)`, поэтому события с тем же `hlc`, но меньшим `id`, не попадают в выдачу. `watchGroup` отдаёт историю группы в порядке `hlc ASC, id ASC`, затем live-записи. Оба потока подписываются на live до чтения истории, буферизуют записи на время replay и подавляют дубли по `id`. Все выборки событий используют `id` как tie-breaker, чтобы пагинация была детерминированной.

## 4. SQLite, upsert и версия

**Минимум — SQLite 3.24.0** (минимальная версия для `ON CONFLICT ... DO UPDATE`). Проверка `SELECT sqlite_version()` выполняется после `ensureOpen` и до чтения/изменения схемы. Версия ниже минимума → `DatabaseVersionTooLow('3.24.0', actual)`; невозможность получить версию → `OpenFailure`. Фактическая версия попадает в `StorageInfo.sqliteVersion`.

Где действительно используется upsert:

| Место | Операция | Семантика |
|-------|----------|-----------|
| `schema_info` (`_setStoredVersion`) | `INSERT ... ON CONFLICT(id) DO UPDATE SET version = ?` | обновление служебной версии схемы |
| `events` | `INSERT OR IGNORE` | неизменяемый лог; дубль по `id` игнорируется |
| `members` | `INSERT OR IGNORE` | повторное добавление участника не меняет `joined_at` |
| `groups`, `channels`, `peers`, `group_settings`, `blobs_meta`, `blob_transfers`, `sync_state` | `INSERT OR REPLACE` | справочники: побеждает последняя запись |

Для `events` `INSERT OR REPLACE`/`DO UPDATE` запрещены: событие неизменяемо, правки моделируются новым событием с новым `id`.

**Источник SQLite.** Android: `sqlite3_flutter_libs` 0.5.41 и `sqlite3` 2.9.4,
bundled-библиотека 3.51.1 по данным пакета. Linux: тот же пакет в Flutter-сборке;
вне Flutter-приложения загрузчик `sqlite3` использует системную `libsqlite3.so`, её
отсутствие преобразуется в `ResourceMissing` с инструкцией по установке
`libsqlite3-dev`. Web: `sqlite3.wasm` релиза `sqlite3` 2.9.4. Runtime-версия и
фактически загруженная библиотека в собранных Android/Linux приложениях не
подтверждены (Q25, Q28).

**Настройки native-подключения.** Для файла и памяти выполняются `PRAGMA foreign_keys = ON`, `PRAGMA journal_mode = WAL`, `PRAGMA synchronous = FULL`. В DDL внешние ключи не объявлены, поэтому `foreign_keys` — страховка на будущее, а не текущая ссылочная целостность. `WAL` и `FULL` выбраны как более строгий режим, но не являются обещанием сохранности последнего commit при потере питания (Q27).

## 5. Схема и миграции

Текущая версия — **8**. Свежая установка создаёт все таблицы, индексы и append-only триггеры из `schema.dart` и записывает версию в `schema_info`. Миграции и обновление версии выполняются одной транзакцией (`_migrate`), поэтому сбой посередине не оставляет частично мигрированную схему.

Таблицы: `events`, `groups`, `members`, `channels`, `peers`, `blobs_meta`, `sync_state`, `pending_events`, `group_settings`, `blob_transfers`, `schema_info`.

Индексы: `idx_events_group_hlc(group_id, hlc)`, `idx_events_author_hlc(author, hlc)`, `idx_events_channel_hlc(channel_id, hlc)`, `idx_channels_group_id(group_id)`, `idx_blobs_group_expires(group_id, expires_at)`, `idx_group_settings_group_key(group_id, key)`, `idx_pending_events_group_hlc(group_id, hlc, id)`. Индекс `(author, seq)` из исходного задания заменён на `(author, hlc)`: в доменной модели нет `seq`, HLC — единственный порядковый ключ события, а `seq` удалён в v6.

Порядок чтения событий — `hlc ASC, id ASC` (для каналов — `hlc DESC, id DESC`, новые сверху). Колонка `seq` и индекс `(author, seq)` удалены: в v3 убран индекс, в v6 — сама колонка.

| Переход | Действие |
|---------|----------|
| 1 → 2 | создать `group_settings` и индекс `(group_id, key)` |
| 2 → 3 | удалить `idx_events_author_seq`, создать `idx_events_author_hlc` |
| 3 → 4 | шагов нет: версия закрепляет контракт записи; строки не преобразуются |
| 4 → 5 | создать триггеры `events_append_only_no_update` и `events_append_only_no_delete` |
| 5 → 6 | удалить `seq` пересборкой `events` с сохранением данных и пересозданием индексов/триггеров |
| 6 → 7 | создать `pending_events` и индекс `(group_id, hlc, id)` для очереди отложенных событий |
| 7 → 8 | создать `blob_transfers(file_id, chunk_index, bytes, received_at)` для персистентных чанков |

Строки v3 с пустым `author` сохраняются как карантинные: payload не декодируется, автор не восстанавливается автоматически. Строки с заполненным `author` сохраняются без изменений. Триггеры v5 запрещают `UPDATE`/`DELETE` событий на уровне SQLite. Миграция v5→v6 использует пересборку таблицы, а не `DROP COLUMN`, чтобы не поднимать минимум SQLite выше 3.24.0. Таблица `pending_events` не является append-only: строка удаляется после успешного применения события или LRU-eviction; `events` по-прежнему защищена триггерами. `blob_transfers` хранит только принятые чанки; повторная запись индекса заменяет данные и не увеличивает `totalBytes`. Миграции применяются по возрастанию целевой версии; неизвестная будущая версия схемы не мигрируется и не понижается. Ручные снимки схем v3 и v5 находятся в `test/schema_v3_snapshot.dart` и `test/schema_v5_snapshot.dart`; генерация через `drift_dev` не закреплена (Q26).

## 6. Web: ресурсы, реализации и деградация

`WebDatabaseFactory` использует `package:drift/wasm.dart`; в `core_storage` этот импорт отсутствует.

| Ресурс | Источник | SHA-256 |
|--------|----------|---------|
| `drift_worker.js` | релиз Drift 2.31.0 | `f0a9b87085f732fd7b6ee7eb34d3858c556f05d221eb1febfc443649cd365752` |
| `sqlite3.wasm` | релиз `sqlite3` 2.9.4 | `922a76b182b6af69b030c8e2fdd3283ecc8e827248b20e4b1f3f3db170b52117` |

Версии и теги закреплены в `tool/web_assets.lock`, суммы — в `tool/web_assets.sha256`, загрузка и проверка — `tool/fetch_web_assets.sh`. Ресурсы генерируются локально/в CI и не хранятся в Git.

Перед открытием фабрика проверяет HTTP-доступность и Content-Type `sqlite3.wasm` — `application/wasm`. Для persistent-режима дополнительно проверяется `drift_worker.js` с типом `application/javascript`, `text/javascript` или `application/x-javascript`. Ошибка доступа или MIME-типа → `ResourceMissing` с именем ресурса и причиной. В режиме `inMemory` worker не требуется, потому что `WasmDatabase.inMemory` не запускает его.

Соответствие выбранной реализации Drift и `StorageInfo`:

| `WasmStorageImplementation` | `backend` | `isPersistent` | Предупреждение |
|-----------------------------|-----------|----------------|----------------|
| `opfsShared`, `opfsLocks` | `opfs` | да | нет |
| `sharedIndexedDb` | `indexedDb` | да | нет |
| `unsafeIndexedDb` | `indexedDb` | да | нет межвкладочной синхронизации |
| `inMemory` | `memory` | нет | данные не сохраняются после перезагрузки |

Дополнительно, если `missingFeatures` не пуст, в `warnings` перечисляются ограничения браузера. `opfsLocks` требует cross-origin isolation: заголовков `Cross-Origin-Opener-Policy: same-origin` и `Cross-Origin-Embedder-Policy: require-corp`, а также CORP/CORS для кросс-оригинных ресурсов. Без этих заголовков Drift выбирает следующий доступный режим: `opfsShared` (если браузер умеет вложенные воркеры, например Firefox), иначе `sharedIndexedDb`, иначе `unsafeIndexedDb`, и только при полном отсутствии storage API — `inMemory`. `opfsShared` не требует COOP/COEP. Локальная раздача с корректными MIME и COOP/COEP — `tool/serve_web_dev.sh` (`ENABLE_CROSS_ORIGIN_ISOLATION=1`).

Подтверждённая цель компиляции — dart2js. `dart2wasm` не проверен (Q30). Перезагрузка настоящей страницы и две вкладки проверяются вручную (Q31).

## 7. Тесты и бюджет

Общий контракт `runEventStoreContract` (`test/event_store_contract.dart`) и общий поведенческий набор `runPortableStorageSuite` (`test/portable_storage_suite.dart`, 12 тестов) импортируются native- и web-раннерами. Набор покрывает схему, идемпотентность, порядок `hlc/id`, курсор, range summary, пагинацию канала, `EventStore`, retention, query plan, append-only и миграции v3→v8/v5→v6. Native-раннер — `test/portable_storage_native_test.dart`, Chrome-раннер — `platform_web/test/portable_storage_web_test.dart`.

Статус приёмки раунда 2 считается только по полному прогону пакета без фильтров:

| Набор | Команда | Результат |
|-------|---------|-----------|
| core_storage (VM) | `dart test` в `packages/core_storage` | 93 пройдено, 0 провалов |
| core_domain (VM) | `dart test` в `packages/core_domain` | 25 пройдено, 0 провалов |
| platform_linux (native) | `flutter test` в `packages/platform_linux` | 7 пройдено, 0 провалов |
| platform_web (Chrome) | `bash tool/test_web_full_chrome.sh` | 30 пройдено, 0 провалов |

Бюджет: вставка 100k событий < 30 000 мс, p95 пагинации < 200 мс. Замеры
выполняются тестами `packages/core_storage/test/performance_test.dart` (VM) и
`packages/platform_web/test/storage_performance_web_test.dart` (Chrome); актуальные
цифры печатаются в выводе тестов.

## 8. Остаточные ограничения

- Q25/Q28: runtime-версия и источник SQLite в собранных Android/Linux приложениях не проверены.
- Q27: power-loss durability `WAL` + `FULL` не подтверждена для целевых файловых систем и накопителей.
- Q29: `sqlite3_flutter_libs` 0.5.41 помечен upstream как устаревающий; стратегия перехода не определена.
- Q30: dart2wasm не проверен.
- Q31: reload страницы и две вкладки не автоматизированы.
- S4-12: автоматизация Android runtime не настроена; проверка вынесена в ручной QA
  (`docs/MANUAL_QA.md`) и остаётся непроверенной до выполнения чек-листа.
