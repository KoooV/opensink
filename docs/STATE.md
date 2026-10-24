# Состояние
## Сделано
- core_group: журнал+replay, топопорядок, genesis-дубликаты, лимит журнала, snapshot-валидация, StateRegression, атрибуция ротации, сериализация apply; 69 тестов.
- core_sync↔core_group: SyncEventKind 11–15, поля GroupEvent, GroupEventCodec, GroupSyncBridge; `dart analyze` core_group и core_sync чисто, существующие тесты 69+36 проходят.
- core_relay: presence-топология, direct-first fallback, RelayFrame/TTL/антипетли, opt-in и лимиты источника, MemberRelay; 11 тестов, analyze чисто. Ревью 2026-10-24: R-01…R-15 в DEFECTS.
## Дальше
- Тесты GroupEventCodec и GroupSyncBridge (round-trip, publish, start, open/approval); подключение моста в DI. `core_relay`: закрыть R-01…R-09, подпись presence (Q37) и production DI в `apps/app`.
## Открытые вопросы
- Legacy GroupState; trusted time (Q36); аутентификация снапшота и fingerprints как хэш; ротация GroupSecret при удалении; подпись presence (Q37).
