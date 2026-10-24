# Состояние
## Сделано
- core_group: журнал+replay, топопорядок, genesis-дубликаты, лимит журнала, snapshot-валидация, StateRegression, атрибуция ротации, сериализация apply; 69 тестов.
- core_sync↔core_group: SyncEventKind 11–15, поля GroupEvent, GroupEventCodec, GroupSyncBridge; `dart analyze` core_group и core_sync чисто, существующие тесты 69+36 проходят.
## Дальше
- Тесты GroupEventCodec и GroupSyncBridge (round-trip, publish, start, open/approval); подключение моста в DI. Minor: fingerprints как хэш, формат сериализации снапшота.
## Открытые вопросы
- Legacy GroupState; trusted time (Q36); аутентификация снапшота и fingerprints как хэш; ротация GroupSecret при удалении.
