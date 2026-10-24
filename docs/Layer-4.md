Слой: core_storage на drift.
Задача:
1. Схема: events (append-only, id = хэш, group, author, hlc, bytes), groups, members, channels, peers, blobs_meta, sync_state.
2. Native: sqlite3_flutter_libs. Web: drift WASM + OPFS/IndexedDB; опиши требования к заголовкам хостинга (COOP/COEP) и деградацию, если они недоступны. Пометь неясное как TODO(verify).
3. Идемпотентная вставка по id события; индексы (group, hlc), (author, seq).
4. Запросы для синхронизации: сводки по диапазонам hlc (счётчик + хэш диапазона), выборка пачками.
5. Миграции и тесты миграций; политика очистки (retention) для вложений.
6. Реализация EventStore из слоя 1 + запросы чтения для UI (пагинация по каналу).
Приёмка: одинаковый набор тестов проходит на native и в Chrome; 100k событий — вставка и пагинация укладываются в заданный тобой бюджет (укажи цифры).