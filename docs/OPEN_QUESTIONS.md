# Открытые вопросы

Список содержит только незакрытые вопросы. Нумерация `Q*` сохранена для совместимости
с design doc-ами пакетов; пропуски означают закрытые вопросы. Индекс `TODO(verify)`
сверяется с кодом скриптом `tool/check_docs_drift.sh`.

## Индекс TODO(verify)

| # | Маркер | Вопрос |
|---|--------|--------|
| TODO-01 | `packages/core_crypto/test/bip39_integrity_test.dart:55` | Q33 |
| TODO-02 | `packages/core_crypto/test/bip39_integrity_test.dart:172` | Q33 |
| TODO-04 | `packages/core_media/lib/core_media.dart:3` | Q13 |
| TODO-06 | `packages/core_signaling/lib/src/nostr_signaling.dart:31` | Q17 |
| TODO-07 | `packages/core_signaling/lib/src/tracker_signaling.dart:28` | Q17 |
| TODO-08 | `packages/core_storage/test/schema_v3_snapshot.dart:3` | Q26 |
| TODO-09 | `packages/core_sync/lib/src/hlc_validator.dart:17` | Q32 |

## Q2 — Production DI для неподключённых портов

Хранилище, identity и `SyncEngineImpl` подключены к реальным реализациям. Для
`SignalingChannel`, `PeerLink`, `Transport`, `Relay`, `MediaTopology`, `IGroupState`
и `ScreenCaptureSource` в `apps/app` пока используются fakes или заглушки. Нужно
определить composition root и конфигурацию (STUN, реле, трекеры) для каждого слоя.

## Q7 — Обоснование MAX_SKIP и TTL пропущенных ключей

`maxSkip = 100` и TTL 24 часа выбраны как компромисс; независимого источника
требований нет. Нужно зафиксировать пороги после анализа replay/DoS и профиля
мобильных сетей.

## Q10 — Ротация signed prekey без сервера

TTL SPK (предлагается 7 дней), grace period и распространение новой SPK без
координатора остаются открытыми. Триггер ротации должен определить слой групп.

## Q13 — `core_media`: звонки, экран, топологии

`packages/core_media/lib/core_media.dart:3` содержит `TODO(verify)`. Нужно
реализовать `MediaTopology`, управление звонками и захват экрана.

## Q17 — `core_signaling`: публичная инфраструктура и LAN/QR

Реализованы Nostr и WebTorrent-трекеры, пул реле и защищённый кодек. Остаются:

- актуальность и политика публичных реле/трекеров (`TODO(verify)` в
  `nostr_signaling.dart` и `tracker_signaling.dart`);
- совместимость не-SDP поля `sdp` с конкретными публичными трекерами;
- NIP-42 AUTH у части реле;
- LAN/QR реализации `SignalingChannel`;
- реальный браузерный `WebSocket.connect` в CI (сейчас web-тесты используют
  fake-реле).

Детальный backlog — Q35.

## Q20 — Linux-сборка `flutter_secure_storage`

Версия 9.2.4 закреплена, но нужно подтвердить сборку на целевых Linux-дистрибутивах
и соответствие опций плагина README.

## Q21 — Мок `FlutterSecureStorage` в тестах

Плагин не предоставляет интерфейс; тесты используют ручной `implements`. Нужно
проверить, что мок покрывает все публичные члены и не сломается при обновлении.

## Q22 — Android Auto Backup

Нужно зафиксировать точные настройки `AndroidManifest.xml` (`allowBackup`,
`fullBackupContent`, исключения) для `flutter_secure_storage` 9.2.4 и поведение при
восстановлении на новом устройстве с недействительным ключом Keystore.

## Q23 — Linux `integration_test` под `dbus-run-session`

Запуск тестов SecureKeyStore с `dbus-run-session` и запущенным keyring в CI не
проверен.

## Q24 — Проверка libsecret при инициализации

`LinuxSecureKeyStoreImpl.checkDependencies()` делает probe-запись. Нужно
подтвердить, что этого достаточно для определения недоступности Secret Service и
что probe не оставляет побочных эффектов.

## Q25 — Версия SQLite в собранных приложениях

Минимум 3.24.0 проверяется при открытии. Фактическая версия SQLite в Android APK и
Linux bundle не подтверждена; нужно сверить `StorageInfo.sqliteVersion` на целевых
сборках.

## Q26 — `drift_dev` и schema dump

`drift_dev` отсутствует в lock-файле, снимки v3/v5 созданы вручную. Нужно закрепить
совместимую версию, проверить команду schema dump и заменить ручные снимки
сгенерированными.

## Q27 — Durability при потере питания

Native-фабрики используют `foreign_keys = ON`, `journal_mode = WAL`,
`synchronous = FULL`. Это не гарантирует сохранность последнего commit при
отключении питания. Нужно подтвердить поведение для Android/Linux файловых систем и
накопителей.

## Q28 — Источник SQLite в собранных приложениях

`sqlite3_flutter_libs` 0.5.41 поставляет bundled SQLite 3.51.1, но фактически
загруженную библиотеку в Android APK и Linux bundle нужно проверить. Зафиксировать
способ проверки и версию из `StorageInfo`.

## Q29 — Поддержка `sqlite3_flutter_libs` 0.5.41

Пакет помечен upstream как устаревающий. Нужна стратегия поставки bundled SQLite
после обновления `sqlite3`/Flutter без отдельного обновления без проверки native ABI
и `StorageInfo.sqliteVersion`.

## Q30 — `dart2wasm`

Web StorageBackend проверен с dart2js. `sqlite3` считает dart2wasm поддержку
экспериментальной; приложение через dart2wasm не собиралось. Нужно собрать и
прогнать storage contract в целевом Chrome.

## Q31 — Перезагрузка страницы и две вкладки

Chrome-тесты проверяют reopen в той же странице, но не реальный reload приложения и
не две вкладки. Нужен browser/integration runner либо выполнение чек-листа из
`docs/MANUAL_QA.md`.

## Q32 — Дрейф HLC на целевых устройствах

`packages/core_sync/lib/src/hlc_validator.dart:17` содержит `TODO(verify)`:
измерить реальный дрейф часов Android/Linux/Web и уточнить
`maxClockSkewMs = 30 000`. Сейчас отклоняются только будущие HLC, прошлые метки
принимаются для истории.

## Q33 — BIP-39 wordlist и NFKD

`packages/core_crypto/test/bip39_integrity_test.dart:55` требует независимой сверки
SHA-256 эталонного wordlist, строка 172 фиксирует отказ от Unicode-нормализации без
`unorm_dart`. Обе проверки остаются открытыми; не-ASCII passphrase явно отклоняется.

## Q35 — Backlog `core_signaling`

Полные критерии закрытия — в `packages/core_signaling/DESIGN.md` §7–8.

| ID | Задача | Статус | Следующий шаг |
|----|--------|--------|---------------|
| SIG-OPEN-01 | Держатель инвайта без `group_secret` | deferred | Design doc: invite-token и отдельный authorizer; не переиспользовать payload-ключ группы. |
| SIG-OPEN-02 | Публичные Nostr-реле и WebTorrent-трекеры | open | Проверить NIP-11, write/read smoke и политику; закрепить список с датой, добавить override и fallback. |
| SIG-OPEN-03 | NIP-42 AUTH | deferred | Обработать `AUTH`-челлендж, хранить auth-state, ограничить reconnect при отказе. |
| SIG-OPEN-04 | Реальные трекеры и не-SDP `sdp` | accepted-risk | Прогнать `bittorrent-tracker` и публичные трекеры, зафиксировать матрицу `offer`/`answer`/`offer_id`/`to_peer_id`. |
| SIG-OPEN-05 | Реальный браузерный `WebSocket.connect` | open | Поднять локальный WS-сервер и прогнать Chrome-тест с реальным подключением. |
| SIG-OPEN-06 | LAN/QR реализации `SignalingChannel` | deferred | Отдельная задача: discovery и QR-инвайт за тем же интерфейсом. |
| SIG-OPEN-07 | Персистентность replay-кэша | accepted-risk | Оценить угрозу рестарта в пределах clock skew; при необходимости хранить nonces в `core_storage`. |
| SIG-OPEN-08 | Hardening `NostrEphemeralSigner` | open | Скрыть `privateKeyHex`, оставить test-only factory, исключить ключ из `toString`/логов. |

## Q36 — Бэкдейтинг HLC первого события

HLC/timestamp группового события самозаявляемы. `prevId` и неубывающий HLC
закрывают бэкдейтинг для автора с историей, но новый участник (или автор без
предыдущих событий) может указать join раньше истечения инвайта. Watermark на
ingest отсекал бы поздние легитимные события; полное решение — trusted time или
причинный DAG/квитанции. Решение poll (2026-10-24): оставить принятый риск;
проверка опирается на `inviteProof` и срок по HLC события.

## Q37 — Подпись presence-анонсов

Решение poll: presence-анонсы (`neighbors`, `can_relay`, capacity) должны быть
подписаны Ed25519; до реализации топология `core_relay` считается недоверенной.
Следующий шаг — расширить `PresenceCodec`/`RichSignalingChannel` подписью и
проверкой в `core_signaling`, затем передавать проверенные анонсы в
`RelayTopology`.

## Q38 — Доверенный genesis и создание groupId

Ревью 2026-10-25 (G-01, G-02): выбор genesis по локальному `(HLC,id)` и
автосоздание `GroupId('main')` позволяют закрепить чужой/бэкдейтнутый корень или
получить форк. Нужно решить источник доверия: сохранённые метаданные группы,
инвайт или отдельный authorizer; когда генерируется groupId; как UI показывает
конфликт genesis. До решения restore должен быть fail-closed.

## Q39 — Персистентность GroupSecret

Ревью 2026-10-25 (G-06): без сохранённого `GroupSecret` production-DI не может
подключить `GroupInviteProofVerifier`, а после рестарта invite-члены не
восстанавливаются. Нужно выбрать хранилище секрета группы (SecureKeyStore,
Vault) и политику ротации при удалении участника.

## Принятые допущения

- HLC цепочки `prevId` неубывающий; равный HLC соседних событий автора допустим.
- Дубликат `id` с разными телами разрешается детерминированным выбором тела
  внутри группы; для genesis — меньшим валидным телом. События чужих `groupId`
  отбрасываются до дедупликации. Прямой `apply` возвращает `EventIdCollision`,
  контроллер выбирает тело из журнала.
- `core_group` получает из `core_sync` события с проверенным
  `id == SHA-256(canonical body)`; выбор тела не заменяет проверку id.
- Корень группы обязателен: `expectedGroupId` и `genesisEventId` в
  `GroupState.fromEvents` и конструкторе `GroupController`.
- Форк цепочки: `fromEvents` выбирает меньшего HLC-валидного ребёнка;
  `GroupController` хранит журнал и пересчитывает проекцию, поэтому порядок
  доставки и форки сходятся.
- `appliedEventIds`/fingerprints содержат только chain-валидные события;
  снапшот с непустым `appliedEventIds` требует согласованные
  курсоры/fingerprints и иначе отклоняется.
- Журнал `GroupController` ограничен `maxJournalEvents`; конкурентные `apply`
  сериализуются; поздний форк с откатом `keyEpoch` даёт `StateRegression`,
  ротация атрибутируется событию, реально поднявшему эпоху.
- `MemberJoined` требует HMAC `inviteProof`; production-адаптер —
  `GroupInviteProofVerifier` в `apps/app` (SIG-OPEN-01 не переиспользует
  payload-ключ группы).
- `GroupSecret` = членство; отдельный invite-путь отложен (SIG-OPEN-01).
- Публичные реле/трекеры остаются дефолтом с `TODO(verify)` (SIG-OPEN-02).
- `neighbors` в hello — caller-supplied; signaling не ведёт топологию.
- WebTorrent payload остаётся `opensink:1:base64url` в `sdp` (SIG-OPEN-04).
- Replay-кэш in-memory, TTL 5 минут (SIG-OPEN-07).
- Health-score неподключённого реле — `0.0`.
- Web-тесты используют fake-реле на `package:web_socket/testing.dart` (SIG-OPEN-05).
- E2E-шифрование payload — ответственность вызывающего слоя/`core_crypto`;
  `core_relay` видит только заголовок и непрозрачные байты.
- Дубль при позднем завершении direct-send допустим и поглощается sync-дедупом.
- ACK от релея не вводится; failover и потеря кадра компенсируются sync.
- Production-сборка `RelayTransport`, relay-канала и opt-in — в `apps/app` DI.
