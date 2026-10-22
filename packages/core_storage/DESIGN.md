# Design doc: core_storage — drift event store (слой 4, этапы F4.1–F4.4)

Статус: документ пересобран по коду этапов F4.1–F4.4. Источник фактов — `packages/core_storage/lib`, платформенные фабрики `packages/platform_*`, `pubspec.lock` (закреплены `drift` 2.19.1+1, `sqlite3` 2.4.5, `sqlite3_flutter_libs` 0.5.41) и выполненные проверки из `docs/LAYER4_ACCEPTANCE.md`. Утверждения о несуществующем пакете `drift_wasm`, «web stub» и «AC3 откладывается» удалены как не соответствующие коду.

## 1. Границы пакетов

`core_storage` — чистый Dart. Разрешённая зависимость уровня drift — только `package:drift/drift.dart`; также используются `core_domain` (модели и контракты), `package:crypto` (SHA-256 для range summary) и `package:meta` (`@internal`). В `core_storage/lib` запрещены `package:drift/native.dart`, `package:drift/wasm.dart`, `dart:io`, `dart:ffi`, `dart:html`, `package:web`, `dart:js_interop`, `sqlite3_flutter_libs`, `path_provider`.

Открытие платформенного подключения выполняют пакеты:

| Пакет | Реализация | Ресурс SQLite |
|-------|------------|---------------|
| `platform_android` | `AndroidDatabaseFactory implements StorageBackend` | bundled SQLite из `sqlite3_flutter_libs` 0.5.41 |
| `platform_linux` | `LinuxDatabaseFactory implements StorageBackend` | bundled SQLite из `sqlite3_flutter_libs` 0.5.41 либо системная `libsqlite3.so` вне Flutter-сборки |
| `platform_web` | `WebDatabaseFactory implements StorageBackend` | `sqlite3.wasm` + `drift_worker.js` |

`core_storage` экспортирует `AppDatabase`, `DriftEventStore`, `RetentionPolicy`, схему, `EventData`, `RangeSummary`, `RangeSummaryError`, `StorageSpec`, `StorageInfo`, `OpenedStorage`, `StorageBackend`, `StorageOpenError`, расширение `StorageBackendResult.openResult`. Типы `Result`, `InsertOutcome` и `EventStoreWriteError` приходят из `core_domain`; `core_storage` их не реэкспортирует. Неиспользуемый `DatabaseFactory` удалён из публичного API; единственный контракт открытия — `StorageBackend`.

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

`RangeSummary` строится по SHA-256 от `ids.join('|')` в UTF-8. Если событий больше `limit` (по умолчанию 100000), возвращается `Err(RangeTooLarge(limit))`, усечённый digest не выдаётся.

`watchFrom(cursor)` отдаёт историю с события `cursor` включительно (`hlc ASC, id ASC`), затем live-записи; пустой/неизвестный курсор означает начало истории. `watchGroup` отдаёт историю группы в порядке `hlc ASC`, затем live-записи. Оба потока подписываются на live до чтения истории, буферизуют записи на время replay и подавляют дубли по `id`.

## 4. SQLite, upsert и версия

**Минимум — SQLite 3.24.0** (минимальная версия для `ON CONFLICT ... DO UPDATE`). Проверка `SELECT sqlite_version()` выполняется после `ensureOpen` и до чтения/изменения схемы. Версия ниже минимума → `DatabaseVersionTooLow('3.24.0', actual)`; невозможность получить версию → `OpenFailure`. Фактическая версия попадает в `StorageInfo.sqliteVersion`.

Где действительно используется upsert:

| Место | Операция | Семантика |
|-------|----------|-----------|
| `schema_info` (`_setStoredVersion`) | `INSERT ... ON CONFLICT(id) DO UPDATE SET version = ?` | обновление служебной версии схемы |
| `events` | `INSERT OR IGNORE` | неизменяемый лог; дубль по `id` игнорируется |
| `members` | `INSERT OR IGNORE` | повторное добавление участника не меняет `joined_at` |
| `groups`, `channels`, `peers`, `group_settings`, `blobs_meta`, `sync_state` | `INSERT OR REPLACE` | справочники: побеждает последняя запись |

Для `events` `INSERT OR REPLACE`/`DO UPDATE` запрещены: событие неизменяемо, правки моделируются новым событием с новым `id`.

**Источник SQLite.** Android: `sqlite3_flutter_libs` 0.5.41 и `sqlite3` 2.4.5, bundled-библиотека 3.51.1 по данным пакета. Linux: тот же пакет в Flutter-сборке; вне Flutter-приложения загрузчик `sqlite3` использует системную `libsqlite3.so`, её отсутствие преобразуется в `ResourceMissing` с инструкцией по установке `libsqlite3-dev`. Web: `sqlite3.wasm` релиза `sqlite3` 2.4.5. Runtime-версия и фактически загруженная библиотека в собранных Android/Linux приложениях не подтверждены (Q25, Q28).

**Настройки native-подключения.** Для файла и памяти выполняются `PRAGMA foreign_keys = ON`, `PRAGMA journal_mode = WAL`, `PRAGMA synchronous = FULL`. В DDL внешние ключи не объявлены, поэтому `foreign_keys` — страховка на будущее, а не текущая ссылочная целостность. `WAL` и `FULL` выбраны как более строгий режим, но не являются обещанием сохранности последнего commit при потере питания (Q27).

## 5. Схема и миграции

Текущая версия — **6**. Свежая установка создаёт все таблицы, индексы и append-only триггеры из `schema.dart` и записывает версию в `schema_info`.

Таблицы: `events`, `groups`, `members`, `channels`, `peers`, `blobs_meta`, `sync_state`, `group_settings`, `schema_info`.

Индексы: `idx_events_group_hlc(group_id, hlc)`, `idx_events_author_hlc(author, hlc)`, `idx_events_channel_hlc(channel_id, hlc)`, `idx_channels_group_id(group_id)`, `idx_blobs_group_expires(group_id, expires_at)`, `idx_group_settings_group_key(group_id, key)`.

Порядок чтения событий — `hlc ASC` (для каналов — `hlc DESC`, новые сверху). Колонка `seq` и индекс `(author, seq)` удалены: в v3 убран индекс, в v6 — сама колонка.

| Переход | Действие |
|---------|----------|
| 1 → 2 | создать `group_settings` и индекс `(group_id, key)` |
| 2 → 3 | удалить `idx_events_author_seq`, создать `idx_events_author_hlc` |
| 3 → 4 | шагов нет: версия закрепляет контракт записи; строки не преобразуются |
| 4 → 5 | создать триггеры `events_append_only_no_update` и `events_append_only_no_delete` |
| 5 → 6 | удалить `seq` пересборкой `events` с сохранением данных и пересозданием индексов/триггеров |

Строки v3 с пустым `author` сохраняются как карантинные: payload не декодируется, автор не восстанавливается автоматически. Строки с заполненным `author` сохраняются без изменений. Триггеры v5 запрещают `UPDATE`/`DELETE` событий на уровне SQLite. Миграция v5→v6 использует пересборку таблицы, а не `DROP COLUMN`, чтобы не поднимать минимум SQLite выше 3.24.0. Миграции применяются по возрастанию целевой версии; неизвестная будущая версия схемы не мигрируется и не понижается. Ручные снимки схем v3 и v5 находятся в `test/schema_v3_snapshot.dart` и `test/schema_v5_snapshot.dart`; генерация через `drift_dev` не закреплена (Q26).

## 6. Web: ресурсы, реализации и деградация

`WebDatabaseFactory` использует `package:drift/wasm.dart`; в `core_storage` этот импорт отсутствует.

| Ресурс | Источник | SHA-256 |
|--------|----------|---------|
| `drift_worker.js` | релиз Drift 2.19.1 | `a1bd312c6ed74199ee877e4e22e69d45176f0f729bea7548dc882d2bc5b94360` |
| `sqlite3.wasm` | релиз `sqlite3` 2.4.5 | `6082c7bc2c537ab59cf915c3dcb56b4c054751bef54d16fae2ad25560cd4f8d0` |

Версии и теги закреплены в `tool/web_assets.lock`, суммы — в `tool/web_assets.sha256`, загрузка и проверка — `tool/fetch_web_assets.sh`. Ресурсы генерируются локально/в CI и не хранятся в Git.

Перед открытием фабрика проверяет HTTP-доступность и Content-Type `sqlite3.wasm` — `application/wasm`. Для persistent-режима дополнительно проверяется `drift_worker.js` с типом `application/javascript`, `text/javascript` или `application/x-javascript`. Ошибка доступа или MIME-типа → `ResourceMissing` с именем ресурса и причиной. В режиме `inMemory` worker не требуется, потому что `WasmDatabase.inMemory` не запускает его.

Соответствие выбранной реализации Drift и `StorageInfo`:

| `WasmStorageImplementation` | `backend` | `isPersistent` | Предупреждение |
|-----------------------------|-----------|----------------|----------------|
| `opfsShared`, `opfsLocks` | `opfs` | да | нет |
| `sharedIndexedDb` | `indexedDb` | да | нет |
| `unsafeIndexedDb` | `indexedDb` | да | нет межвкладочной синхронизации |
| `inMemory` | `memory` | нет | данные не сохраняются после перезагрузки |

Дополнительно, если `missingFeatures` не пуст, в `warnings` перечисляются ограничения браузера. Для `opfsLocks` нужны заголовки `Cross-Origin-Opener-Policy: same-origin` и `Cross-Origin-Embedder-Policy: require-corp`; без них Drift выбирает поддерживаемый IndexedDB-режим. Локальная раздача с корректными MIME и COOP/COEP — `tool/serve_web_dev.sh` (`ENABLE_CROSS_ORIGIN_ISOLATION=1`).

Подтверждённая цель компиляции — dart2js. `dart2wasm` не проверен (Q30). Перезагрузка настоящей страницы и две вкладки проверяются вручную (Q31).

## 7. Тесты и бюджет

Общий контракт `runEventStoreContract` (`test/event_store_contract.dart`) импортируется native- и web-тестами: запись, чтение, дубль без перезаписи, `author`, `sqliteVersion`, предупреждение для памяти.

Статус приёмки раунда 2 считается только по полному прогону пакета без фильтров:

| Набор | Команда | Результат |
|-------|---------|-----------|
| core_storage (VM) | `dart test` в `packages/core_storage` | 69 пройдено, 0 провалов |
| core_domain (VM) | `dart test` в `packages/core_domain` | 25 пройдено, 0 провалов |
| platform_linux (native) | `flutter test` в `packages/platform_linux` | 7 пройдено, 0 провалов |
| platform_web (Chrome) | `dart test -p chrome -c dart2js` | 18 пройдено, 0 провалов |

Фактический VM-замер из полного прогона (одна in-memory БД, 100k вставок одной транзакцией, 10 страниц по 50 записей): вставка 2 661 мс, pagination p95 5 мс при порогах < 30 000 мс / < 200 мс. Chrome-замер из полного прогона: `WEB_STORAGE_PERF events=100000 insert_ms=4965 pagination_p95_ms=4`. Подробности и команды — `docs/LAYER4_ACCEPTANCE.md`.

## 8. Остаточные ограничения

- Q25/Q28: runtime-версия и источник SQLite в собранных Android/Linux приложениях не проверены.
- Q27: power-loss durability `WAL` + `FULL` не подтверждена для целевых файловых систем и накопителей.
- Q29: `sqlite3_flutter_libs` 0.5.41 помечен upstream как устаревающий; стратегия перехода не определена.
- Q30: dart2wasm не проверен.
- Q31: reload страницы и две вкладки не автоматизированы.
- S4-11/S4-12/S4-15: дефекты соседних платформенных файлов и Android runner, вне скоупа слоя 4.
