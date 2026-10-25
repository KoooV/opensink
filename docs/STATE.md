# Состояние
## Сделано
- core_group: журнал+replay, топопорядок, genesis-дубликаты, лимит журнала, snapshot-валидация, StateRegression, атрибуция ротации, сериализация apply; 69 тестов.
- core_sync↔core_group: SyncEventKind 11–15, поля GroupEvent, GroupEventCodec, GroupSyncBridge; `dart analyze` core_group и core_sync чисто, существующие тесты 69+36 проходят.
- core_relay: R-01…R-15, Ed25519-подпись origin (`nonce`+`originTtl`), отдельный `PeerChannels.relay`/`relayIncoming`, Transport/RelayFrame `src`, MemberRelay origin-only, envelope v3, буфер `incoming`, владение `direct`; R-16…R-27 закрыты; Layer-9: локальные линки из `direct.events` для пересылки без presence получателя, AEAD-приёмка A→C→B; seed `initialLocalNeighbors`, RTT из `PeerLinkStats`, наблюдаемая нагрузка из `RelayMetrics`, freshness не продлевается; 62 теста.
- core_domain/core_group/core_storage/app: доверенный genesis и groupId (GroupMetadataStore, GroupLifecycle, `gen` в InviteLink, fail-closed restore/join); G-01/G-02 закрыты, 96+88 тестов. Ревью reviewer+crypto 2026-10-25: G-12…G-20.
- core_sync/core_group: pinGroupRoot+reindex, ForeignGroupRoot, чужой genesis и его потомки не принимаются и не блокируют группу; bridge start/publish fail-closed, параллельный start ждёт валидации; G-12/G-13/G-14 закрыты, 42 теста core_sync (вкл. sim) и 104 core_group. Повторное ревью (reviewer+crypto): блокеров нет, остаточные G-21…G-24.
- G-03…G-08 закрыты: сериализация lifecycle, preflight publish до записи, Ed25519 при restore, invite fail-closed (Q39), autoDispose bridge, payload/envelope consistency; 111 core_group, 43 core_sync, 8 app.
- G-15…G-24 закрыты: подпись метаданных и инвайт-ссылок, pin до genesis, изоляция pending, verify-before-decode, сериализация refresh/publish, лимит и очистка незакреплённых групп; 125 core_group, core_sync group_root/drift зелёные.
- core_relay poll 2026-10-26: load = скорость от source, `linkStats` callback, seed только при создании, окно 10 с, RTT=0 игнорируется.
- core_relay linkStats в DI: `Transport.statsFor` (WebRTC → `linkFor().stats`), `relayLinkStatsProvider` → `RelayTransport.linkStats`; сквозной тест RTT.
- toolchain: melos 8 `run` исполнялся только в корне, а regex терял двойной пробел; `test` переведён на `exec` с `[[:space:]]`, platform_web исключён (web-jobs CI), корневой шаблонный widget_test удалён, apps/app тесты зелёные.
## Дальше
- `apps/app`: реальный `WebRtcTransport` в `transportProvider` (linkStats уже готов).
- `core_group`: production GroupKeyDistributor/InviteProofVerifier. Follow-up poll 2026-10-25: verified-кэш restore, карантин невалидных записей store.
## Открытые вопросы
- Legacy GroupState; trusted time (Q36); аутентификация снапшота и fingerprints как хэш; ротация GroupSecret при удалении; Q39 (хранение GroupSecret).
