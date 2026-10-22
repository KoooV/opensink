# LAYER4_ACCEPTANCE.md — приёмка слоя 4 (core_storage)

Этапы F4.4 (schema v6, S4-13, S4-16). Дата фиксации результатов: 2026-10-23. Окружение: Linux, Dart/Flutter из workspace, закреплённые `drift` 2.19.1+1, `sqlite3` 2.4.5, `sqlite3_flutter_libs` 0.5.41. Статусы: **подтверждено** / **не проверено**. Статус «подтверждено» ставится только по полному прогону пакета без фильтров (`-n`, `--name`, списков файлов). Падающий файл делает пакет красным.

## AC1 — схема, идемпотентная вставка, индексы, запросы синхронизации

**Статус: подтверждено.**

Команда (полный набор пакета, без фильтров):

```bash
cd packages/core_storage && dart test
```

Фрагмент вывода:

```text
VM_STORAGE_PERF events=100000 insert_ms=2661 pagination_p95_ms=5
00:08 +69: All tests passed!
```

Что покрыто: `INSERT OR IGNORE` и `InsertOutcome` (новая запись/дубль), сохранение исходных байтов при дубле, `hlc ASC` для группы, `hlc DESC` для канала, `rangeSummary` с SHA-256 и ошибкой лимита, `batchEvents`/`getEventById`, `EXPLAIN QUERY PLAN` для `idx_events_group_hlc` и `idx_events_author_hlc`, 100k вставок и пагинация. В полный набор входят migration-тесты, проверки `id`/`author`, channelId, replay/cursor, append-only триггеров и retention callback.

## AC2 — миграции и тесты миграций

**Статус: подтверждено.**

Тесты миграции входят в полный прогон AC1. Дополнительно:

```bash
dart test packages/core_storage/test/sqlite_open_and_migration_test.dart -p vm
```

Проверено: версия схемы 6; v3 → v6 сохраняет строки с заполненным и пустым `author`, пустой автор остаётся карантинным, payload не декодируется, созданы append-only триггеры; v5 → v6 удаляет `seq` пересборкой таблицы и сохраняет данные события. `migration_test.dart` проходит на схеме v6.

## AC3 — один и тот же набор тестов на native и в Chrome

**Статус: подтверждено.**

Native-часть подтверждена полным прогоном пакета:

```bash
cd packages/platform_linux && flutter test
```

Фрагмент вывода:

```text
00:00 +7: All tests passed!
```

Chrome-часть подтверждена полным прогоном `packages/platform_web` без фильтров:

```bash
cd packages/platform_web && dart test -p chrome -c dart2js
```

Фрагмент вывода:

```text
00:06 +18: All tests passed!
```

S4-13 исправлен: Web SecureKeyStore проходит общий контракт и негативы, storage-тесты выполняются в том же полном прогоне.

## AC4 — бюджет 100k событий с цифрами

**Статус: подтверждено для Dart VM и Chrome.**

VM-замер из полного прогона AC1:

```text
VM_STORAGE_PERF events=100000 insert_ms=2661 pagination_p95_ms=5
```

Порог слоя 4: вставка < 30 000 мс, p95 пагинации < 200 мс. VM в пороге. Chrome-замер из полного прогона platform_web: `WEB_STORAGE_PERF events=100000 insert_ms=4965 pagination_p95_ms=4`; Chrome также в пороге.

## AC5 — чистота core_storage (нет платформенных импортов)

**Статус: подтверждено.**

Команды:

```bash
bash tool/check_core_imports.sh
bash tool/check_core_storage_deps.sh
grep -rInE "package:drift/(native|wasm)\.dart|dart:(io|ffi|html|js_interop)|package:web/|package:(sqlite3_flutter_libs|path_provider)/" packages/core_storage/lib
```

Фрагмент вывода:

```text
check_core_imports: OK — нет запрещённых импортов в core_* пакетах
check_core_storage_deps: OK — sqlite3_flutter_libs и path_provider отсутствуют
0 matches
```

`core_storage/pubspec.yaml` содержит только `core_domain` и `drift`. Платформенные зависимости находятся в `platform_android`, `platform_linux`, `platform_web`.

## AC6 — пустой author невозможен; событие неизменяемо

**Статус: подтверждено** (на границе EventStore).

Проверки входят в полный прогон AC1 (`dart test` в `packages/core_storage`, 69 тестов).

Проверено: пустой `author`, неверная длина и не-hex → `InvalidAuthor`, в БД ничего не пишется; дубль `id` → `inserted = false`, `duplicate = true`, исходные байты не перезаписываются; параллельные записи одного `id` дают ровно одного победителя.

Ограничение: проверка выполняется в `DriftEventStore.write`. Прямой SQL в обход store (например, из тестового или миграционного кода) может вставить пустой `author`; схема объявляет `author NOT NULL`, но не содержит `CHECK`. Это осознанная граница: хранилище не разбирает payload, а автор обязателен в контракте `EventRecord`.

## Дополнительные проверки этапа

### Сборка TODO(verify) и OPEN_QUESTIONS

```bash
grep -rIn "TODO(verify)" packages apps --include='*.dart' | wc -l
grep -cE '^\| TODO-[0-9]+ \|' docs/OPEN_QUESTIONS.md
bash tool/check_docs_drift.sh
```

Вывод: `10` маркеров, `10` записей индекса; `check_docs_drift: OK`.

### Анализатор

Целевая проверка слоя 4:

```bash
dart analyze \
  packages/core_storage/lib \
  packages/core_storage/test/sqlite_version_check_test.dart \
  packages/core_storage/test/migration_test.dart \
  packages/platform_android/lib/src/storage_database_factory.dart \
  packages/platform_linux/lib/src/storage_database_factory.dart \
  packages/platform_web/lib/src/storage_database_factory_web.dart
```

Вывод:

```text
No issues found!
```

Полный `melos run analyze` остаётся **не проверено** как зелёная проверка: предсуществующие diagnostics в других слоях (S4-15 и др.).

### Текстовая гигиена

`bash tool/check_text_hygiene.sh` — **OK**: CJK, диакритика и смешение алфавитов не найдены; бинарные файлы и намеренные Unicode-fixtures (`hygiene-allow`) исключены.

## Сводка

| Критерий | Статус | Доказательство |
|----------|--------|----------------|
| AC1 | подтверждено | полный `dart test` core_storage: 69/69 |
| AC2 | подтверждено | полный прогон включает migration tests; v3 → v6 + v5 → v6 (seq) |
| AC3 | подтверждено | native 7/7; полный Chrome-прогон platform_web 18/18 |
| AC4 | подтверждено | VM 2661/5 мс; Chrome 4965/4 мс |
| AC5 | подтверждено | два скрипта, 0 запрещённых импортов |
| AC6 | подтверждено | полный прогон core_storage, 69/69 |
