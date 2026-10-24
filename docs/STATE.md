# Состояние
## Сделано
- core_group: журнал+replay, топопорядок, genesis-дубликаты, лимит журнала, snapshot-валидация, StateRegression, атрибуция ротации, сериализация apply; 69 тестов.
- core_sync↔core_group: SyncEventKind 11–15, поля GroupEvent, GroupEventCodec, GroupSyncBridge; `dart analyze` core_group и core_sync чисто, существующие тесты 69+36 проходят.
- core_relay: presence-топология, direct-first fallback, RelayFrame/TTL/антипетли, opt-in и лимиты источника, MemberRelay; 11 тестов, analyze чисто. Ревью 2026-10-24: R-01…R-15 в DEFECTS.
- core_domain/core_group/core_storage/app: доверенный genesis и groupId (GroupMetadataStore, GroupLifecycle, `gen` в InviteLink, fail-closed restore/join); G-01/G-02 закрыты, 96+88 тестов. Ревью reviewer+crypto 2026-10-25: G-12…G-20 (2 blocker).
## Дальше
- Сначала G-12/G-13 (fail-open и DoS genesis), затем G-03…G-08, G-14…G-20. `core_relay`: R-01…R-09, подпись presence (Q37), production DI. `core_group`: production GroupKeyDistributor/InviteProofVerifier.
## Открытые вопросы
- Legacy GroupState; trusted time (Q36); аутентификация снапшота и fingerprints как хэш; ротация GroupSecret при удалении; подпись presence (Q37); Q39 (хранение GroupSecret).
