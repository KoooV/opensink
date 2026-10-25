# Состояние
## Сделано
- core_group: журнал+replay, топопорядок, genesis-дубликаты, лимит журнала, snapshot-валидация, StateRegression, атрибуция ротации, сериализация apply; 69 тестов.
- core_sync↔core_group: SyncEventKind 11–15, поля GroupEvent, GroupEventCodec, GroupSyncBridge; `dart analyze` core_group и core_sync чисто, существующие тесты 69+36 проходят.
- core_relay: R-01…R-15, Ed25519-подпись origin (`nonce`+`originTtl`), отдельный `PeerChannels.relay`/`relayIncoming`, Transport/RelayFrame `src`, MemberRelay origin-only, envelope v3, буфер `incoming`, владение `direct`; R-16…R-27 закрыты; Layer-9: локальные линки из `direct.events` для пересылки без presence получателя, AEAD-приёмка A→C→B; seed `initialLocalNeighbors`, RTT из `PeerLinkStats`, наблюдаемая нагрузка из `RelayMetrics`, freshness не продлевается, локальный линк источника входит в выбор релея; исходящий relay не требует opt-in, opt-in только для forwarding; 64 теста.
- core_domain/core_group/core_storage/app: доверенный genesis и groupId (GroupMetadataStore, GroupLifecycle, `gen` в InviteLink, fail-closed restore/join); G-01/G-02 закрыты, 96+88 тестов. Ревью reviewer+crypto 2026-10-25: G-12…G-20.
- core_sync/core_group: pinGroupRoot+reindex, ForeignGroupRoot, чужой genesis и его потомки не принимаются и не блокируют группу; bridge start/publish fail-closed, параллельный start ждёт валидации; G-12/G-13/G-14 закрыты, 42 теста core_sync (вкл. sim) и 104 core_group. Повторное ревью (reviewer+crypto): блокеров нет, остаточные G-21…G-24.
- G-03…G-08 закрыты: сериализация lifecycle, preflight publish до записи, Ed25519 при restore, invite fail-closed (Q39), autoDispose bridge, payload/envelope consistency; 111 core_group, 43 core_sync, 8 app.
- G-15…G-24 закрыты: подпись метаданных и инвайт-ссылок, pin до genesis, изоляция pending, verify-before-decode, сериализация refresh/publish, лимит и очистка незакреплённых групп; 125 core_group, core_sync group_root/drift зелёные.
- core_relay poll 2026-10-26: load = скорость от source, `linkStats` callback, seed только при создании, окно 10 с, RTT=0 игнорируется.
- core_relay linkStats в DI: `Transport.statsFor` (WebRTC → `linkFor().stats`), `relayLinkStatsProvider` → `RelayTransport.linkStats`; сквозной тест RTT.
- apps/app: `SecureGroupSecretStore` + реестр invite-verifier; `transportProvider`/`relay*` по группе строят `WebRtcTransport` (Nostr+Tracker, тема из `GroupSecret`); `WebRtcTransport` публикует direct-соседей через `NeighborAnnouncer`, тесты зелёные.
- toolchain: melos 8 `run` исполнялся только в корне, а regex терял двойной пробел; `test` переведён на `exec` с `[[:space:]]`, platform_web исключён (web-jobs CI), корневой шаблонный widget_test удалён, apps/app тесты зелёные.
- apps/app: `GroupInviteService` (InviteIssued→подписанная ссылка, join+MemberJoined, pending без genesis) и UI Home/Group (список, create, join, выдача/копирование инвайта); 27 тестов apps/app зелёные.
- Layer-10: `ChatService` (6 видов событий), `PresenceService`, `FileTransferService` (16 КиБ, Merkle, докачка, 2 источника), `ChatNotificationRouter`; in-memory тесты 3 пиров и 50 МиБ, 6/6.
- Layer-10 poll 2026-10-25: E2EE до production distributor; file key в payload; BlobStore+notifications+v8; ingress rate+квота; компакция позже.
- core_sync/app: `SyncPacketTransport`+`PacketSyncLink`, `RelayPacketTransport`, `SyncLinkConnector` (direct↔relay, seed из топологии), `activeTransportProvider`=RelayTransport; close линка/коннектора не закрывает транспорт; 33 app и 48 core_sync тестов.
- apps/app+core_storage: production DI Layer-10 (`DriftBlobStore`, `FileTransferService`, in-app `NotificationService`), schema v8 `blob_transfers`, approval-инвайты (issue/join/approve+UI) и QR/share инвайта; 39 app, 93 core_storage тестов.
- apps/app/core_group: OS-уведомления Android/Linux/Web с in-app fallback; sender-key пакет подписан Ed25519 (groupId/epoch/sender/recipient/keyPackage), `E2eSenderKeyDelivery`+`SenderKeyChannel`, подпись в SecureKeyStore, `signer` опционален (fail-closed); production E2E-канал fail-closed.
## Дальше
- `apps/app`: foreground-политика OS/in-app; `core_group`: design+feature E2E-канала (X3DH/DoubleRatchet, bundle в signaling presence).
- `core_sync`: ingress rate limit по автору + квота блобов на группу; компакция read markers/reactions; `core_storage`: квота `blob_transfers` по группе.
## Открытые вопросы
- Legacy GroupState; trusted time (Q36); аутентификация снапшота и fingerprints; ротация GroupSecret при удалении; Q39 (ротация); sender-key G-25…G-35.
