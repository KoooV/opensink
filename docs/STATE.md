# Состояние
## Сделано
- core_group: журнал+replay, топопорядок, genesis-дубликаты, лимит журнала, snapshot-валидация, StateRegression, атрибуция ротации, сериализация apply; 69 тестов.
- core_sync↔core_group: SyncEventKind 11–15, поля GroupEvent, GroupEventCodec, GroupSyncBridge; `dart analyze` core_group и core_sync чисто, существующие тесты 69+36 проходят.
- core_relay: R-01…R-09, Ed25519-подпись origin (`nonce`+`originTtl`), отдельный `PeerChannels.relay`/`relayIncoming`, Transport/RelayFrame `src`, MemberRelay origin-only, envelope v3; 24 теста.
- core_domain/core_group/core_storage/app: доверенный genesis и groupId (GroupMetadataStore, GroupLifecycle, `gen` в InviteLink, fail-closed restore/join); G-01/G-02 закрыты, 96+88 тестов. Ревью reviewer+crypto 2026-10-25: G-12…G-20.
- core_sync/core_group: pinGroupRoot+reindex, ForeignGroupRoot, чужой genesis и его потомки не принимаются и не блокируют группу; bridge start/publish fail-closed, параллельный start ждёт валидации; G-12/G-13/G-14 закрыты, 42 теста core_sync (вкл. sim) и 104 core_group. Повторное ревью (reviewer+crypto): блокеров нет, остаточные G-21…G-24.
## Дальше
- G-03…G-08, G-15…G-24. `core_relay`: R-10…R-15. `core_group`: production GroupKeyDistributor/InviteProofVerifier.
## Открытые вопросы
- Legacy GroupState; trusted time (Q36); аутентификация снапшота и fingerprints как хэш; ротация GroupSecret при удалении; Q39 (хранение GroupSecret).
