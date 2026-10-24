# Состояние
## Сделано
- core_group: журнал+replay, топопорядок, genesis-дубликаты, лимит журнала, snapshot-валидация, StateRegression, атрибуция ротации, сериализация apply; 69 тестов.
- core_sync↔core_group: SyncEventKind 11–15, поля GroupEvent, GroupEventCodec, GroupSyncBridge; `dart analyze` core_group и core_sync чисто, существующие тесты 69+36 проходят.
- core_relay: presence-топология, direct-first fallback, RelayFrame/TTL/антипетли, opt-in и лимиты источника, MemberRelay; 11 тестов, analyze чисто. Ревью 2026-10-24: R-01…R-15 в DEFECTS.
- core_group: тесты GroupEventCodec (12 видов, ошибки) и GroupSyncBridge (publish/start/open/approval); DI моста в `apps/app`: family, earliest genesis + warning, activeGroupId; 83+4 теста, analyze чисто. Ревью 2026-10-25: G-01…G-11 в DEFECTS (2 blocker).
## Дальше
- Сначала закрыть G-01/G-02 (доверенный genesis, groupId), затем G-03…G-08. `core_relay`: R-01…R-09, подпись presence (Q37), production DI. `core_group`: production GroupKeyDistributor/InviteProofVerifier.
## Открытые вопросы
- Legacy GroupState; trusted time (Q36); аутентификация снапшота и fingerprints как хэш; ротация GroupSecret при удалении; подпись presence (Q37); Q38 (genesis/groupId), Q39 (хранение GroupSecret).
