# Открытые дефекты и остаточные риски

Реестр содержит только незакрытые пункты. Исправленные дефекты из реестра удалены;
их история доступна в `git log`. Новые расхождения фиксируются здесь с id, местом,
риском, способом проверки и статусом.

Статусы: **latent** — не проявляется на целевых сценариях; **документирован** —
принятое ограничение; **не проверено** — требуется проверка на целевом окружении.

## Криптография и E2EE

| id | Место | Риск | Проверка / статус |
|----|-------|------|-------------------|
| D-14 | `packages/core_crypto/lib/src/bip39.dart` (`SHA-256` padding) | `bitLen >> i` использует сдвиг до 56 бит. Безопасно для типичных входов (< 256 МБ); в dart2js может быть некорректно для гигантских входных данных. | latent; для мессенджера не критично, отдельных действий не требует. |
| D-21 | `packages/core_crypto/lib/src/state_vault.dart`, `packages/core_crypto/DESIGN.md` §15.4 | Подмена сохранённого состояния старой версией (rollback) может привести к повторному использованию ключей цепочки. | документирован; полная защита требует монотонного счётчика в защищённом хранилище. |
| D-22 | `packages/core_crypto/lib/src/state_vault.dart` | Ключ хранилища не затирается из памяти после использования; Dart VM не гарантирует безопасное обнуление `Uint8List`. | документирован; ограничение платформы, не устраняется на уровне кода. |
| D-23 | `packages/core_crypto/lib/src/state_vault.dart` | Потеря ключа хранилища (очистка данных приложения/браузера) делает сохранённые E2EE-сессии нерасшифровываемыми. | документирован; принятый остаточный риск, сессии устанавливаются заново. |

## Хранение

| id | Место | Риск | Проверка / статус |
|----|-------|------|-------------------|
| S4-10 | `packages/core_storage/test/schema_v3_snapshot.dart` | Снимки старых схем созданы вручную; `drift_dev` не закреплён, поэтому нет автоматической генерации migration-test артефактов. | не проверено; требуется закрепить совместимую версию `drift_dev` и сверить CLI (Q26). |
| S4-12 | `apps/app/android/` | Runtime-версия и источник bundled SQLite в собранном Android-приложении не подтверждены; автоматический integration runner для этого не настроен. | не проверено; обязательный ручной чек-лист — `docs/MANUAL_QA.md` (Q25, Q28). |

## Релей (core_relay, ревью 2026-10-24)

| id | Место | Риск | Проверка / статус |
|----|-------|------|-------------------|
| R-01 | `packages/core_relay/lib/src/relay_transport.dart:203-205,232-240,247,253-260,317-324` | `frame.src` не аутентифицирован, но используется для loop-проверки, кэша, per-source лимита, метрик и `RelayInbound.src`; подделка `src` обходит лимиты и `maxHops`. | blocker; ключевать по `from`, проверять `from == src` на первом хопе, отклонять `src == localPeerId`. |
| R-02 | `packages/core_relay/lib/src/relay_transport.dart:91,253-260,273`; `relay_metrics.dart:22,27-28` | `_sourceBuckets` и `forwardedBytesBySource` не ограничены и ключуются по подделываемому `src`; рост памяти при переборе источников. | major; LRU/eviction и ограничение cardinality метрик. |
| R-03 | `packages/core_relay/lib/src/relay_config.dart:12,16`; `relay_transport.dart:121-124,184-201` | `maxFrameBytes` больше `perSourceBurstBytes`; на отправке лимит по payload, на приёме — по всему кадру; direct-путь ограничен relay-лимитом. | major; единый `maxPayload`/проверка `toBytes().length`, `burst >= maxFrameBytes`. |
| R-04 | `packages/core_relay/lib/src/relay_transport.dart:184-221` | Локальная доставка не применяет token bucket; SHA-256 и парсинг идут до лимитов, что даёт CPU/память DoS. | major; лимит по `from` до парсинга и для `dst == localPeerId`. |
| R-05 | `packages/core_relay/lib/src/relay_transport.dart:262,271,327`; `packages/core_protocol/lib/src/messages.dart:1426-1435` | Bucket списывает `payload.length + 64`, но `forward()` сохраняет `unknownFields`; кадр с большими unknown-полями проходит почти бесплатно. | major; списывать фактический размер и/или отбрасывать unknown-поля. |
| R-06 | `packages/core_relay/lib/src/relay_transport.dart:236-251,302-315` | `_seen` заполняется до проверки маршрута/лимита/успеха; отброшенный кадр блокирует повтор через запасной релей. При `seenMaxEntries == 0` — `StateError`. | major; фиксировать seen после успеха, отдельный in-flight набор, обработать пустой кэш. |
| R-07 | `packages/core_relay/lib/src/member_relay.dart:18-20` | `forward` игнорирует `RelaySendFailed` и через `deliver` пере-оригинирует кадр с локальным `src`/TTL. | major; пробрасывать ошибку и сохранять origin либо зафиксировать origin-only контракт. |
| R-08 | `packages/core_relay/lib/src/relay_transport.dart:106,160,270`; `packages/core_peer/lib/src/transport.dart` | Пересылка идёт через `Transport.send` (control-канал); получатель не отличает `RelayFrame` от обычного payload, `accept` нельзя безопасно подключить. | major; отдельный relay-канал или тег конверта до production DI. |
| R-09 | `packages/core_relay/lib/src/relay_config.dart:14` | `relayEnabled = true` по умолчанию противоречит opt-in и позволяет ретрансляцию без согласия. | major; default `false`, включение через `RelayOptIn`. |
| R-10 | `packages/core_relay/lib/src/relay_transport.dart:241-277` | `accept` пробует один `nextHop`; при сбое `topology.remove(nextHop)` может удалить валидный presence получателя. | minor; перебирать альтернативы, удалять только relay-роль. |
| R-11 | `packages/core_relay/lib/src/relay_topology.dart:46-47,94-102,105-107` | `applyPresence` перезаписывает запись без сравнения `updatedAt`; старый анонс или `at` в будущем меняет маршруты. | minor; монотонность, ограничение будущих меток, подпись presence (Q37). |
| R-12 | `packages/core_relay/lib/src/relay_transport.dart:85-88,212-219,280-300` | Broadcast `incoming` теряет кадры до подписки при уже увеличенном `delivered`; синтетическое `'closed'` вне контракта; `close()` не закрывает `direct`. | minor; определить владение, буферизацию и события. |
| R-13 | `packages/core_relay/pubspec.yaml:15`; `relay_transport.dart:7` | Для не-security fingerprint используется `package:crypto`, формально расходится с hard rule `package:cryptography`. | minor; заменить или локально задокументировать. |
| R-14 | `packages/core_relay/lib/src/relay_transport.dart:90,302-315` | `_seen` защищает только 5 минут; после TTL повтор доставляется. Для group-sync покрыто sync-дедупом, для прочих payload контракт не зафиксирован. | minor; E2E nonce/replay-window или явная документация. |
| R-15 | `packages/core_relay/test/relay_test.dart:241,255`; `packages/core_relay/DESIGN.md:25-26`; `docs/DESIGN.md:50` | Проверка непрозрачности тавтологична; нет тестов oversize/burst/malformed/close/source-disabled/dedupe-after-failure; DESIGN расходится с порядком проверок. | minor; усилить тесты и синхронизировать DESIGN. |

## Группы и DI (ревью 2026-10-25)

Повторное ревью 2026-10-25 (reviewer + crypto-review): G-12…G-20.
G-01/G-02 закрыты, их история — в `git log`.

| id | Место | Риск | Проверка / статус |
|----|-------|------|-------------------|
| G-03 | `packages/core_group/lib/src/group_lifecycle.dart:101-183,300-334`; `packages/core_storage/lib/src/group_metadata_store_impl.dart:64-73` | Нет CAS/сериализации: recovery может удалить метаданные, пока параллельный create сохраняет ready-корень; конкурентные join с разными `gen` дают last-write-wins; create не идемпотентен и не досоздаёт `MemberAdded`. | major; insert-if-absent/CAS по `(groupId, genesisEventId)` или lock по groupId, идемпотентное восстановление участников. |
| G-04 | `packages/core_group/lib/src/group_sync_bridge.dart:104-129`; `packages/core_group/test/group_sync_bridge_test.dart:79` | `publish` пишет, подписывает и gossip-ит событие до `apply`; при `Forbidden`/`InvalidKeyEpoch` оно остаётся в логе и уходит пирам. Тест не покрывает отказ после записи. | major; валидировать через replay/копию контроллера до `createEvent`, добавить негативный кейс. |
| G-05 | `packages/core_sync/lib/src/sync_engine_impl.dart:526`; `packages/core_group/lib/src/group_sync_bridge.dart:170` | Restore-путь загружает записи из store без повторной проверки Ed25519-подписи; bridge перепроверяет только genesis, остальная история применяется без верификации. | major; проверять подпись при загрузке либо хранить verified-флаг; тест с подменённой записью. |
| G-06 | `apps/app/lib/di/providers.dart:159` | `GroupLifecycle` в DI создаётся без `InviteProofVerifier`: production-вход по инвайту всегда получает `InvalidInviteProof`. | major; подключить `GroupInviteProofVerifier` от `GroupSecret` либо явно запретить invite-сценарии до появления хранилища. |
| G-07 | `apps/app/lib/di/providers.dart:211-219,223-228` | `ref.onDispose` регистрируется после `await lifecycle.open`; при dispose во время открытия bridge остаётся подписанным на `engine.changes`. `groupStateProvider` без `autoDispose` держит мост живым навсегда, поэтому `autoDispose` family не срабатывает. | major; cleanup сразу после появления bridge, `autoDispose`/закрытие при смене активной группы. |
| G-08 | `packages/core_group/lib/src/group_event_codec.dart:295-301` | `userId`/`channelId` берутся из payload или envelope без сверки. `MembershipEvaluator` использует `targetId`, а группа — payload, поэтому расхождение даёт разный состав участников. | major; требовать согласованности payload/envelope и добавить negative-тесты. |
| G-09 | `packages/core_group/test/support/fake_sync.dart:30`; `packages/core_group/test/group_event_codec_test.dart:134`; `packages/core_group/test/group_sync_bridge_test.dart:200` | Fake-подпись forgeable, `prevId` проверяется только на непустоту, «идемпотентный start» уходит в early return; не покрыты конфликт после start, publish после `_fatalError`, исключение в start, невалидный/двойной pending, очистка активной группы, негативный invite после старта. | minor; Ed25519 signer, точные утверждения и provider-тесты. |
| G-10 | `packages/core_group/lib/src/group_event_codec.dart:484-486` | Пустой `inviteMode` декодируется как `InviteMode.open`, превращая malformed payload в open-инвайт. | minor; пустое значение — `MalformedGroupEvent`, добавить тест. |
| G-11 | `packages/core_group/lib/src/group_state.dart:782` | Исключение из `InviteProofVerifier.verify` выходит из `apply` вместо `Err(InvalidInviteProof)`. | minor; try/catch и тест с throw-verifier. |
| G-12 | `packages/core_group/lib/src/group_sync_bridge.dart:71-108`; `apps/app/lib/di/providers.dart:211-219` | Fail-open после genesis-конфликта: `_started = true` до валидации, параллельный `start()` получает `Ok`; `publish()` не проверяет `_fatalError`, поэтому после `GenesisConflict`/`GenesisMissing` события продолжают подписываться, писаться в лог, gossip-иться и применяться к замороженному контроллеру. | blocker; `Ok` только после валидации; `publish()` требует `_fatalError == null`; отдельный путь для create. |
| G-13 | `packages/core_group/lib/src/group_sync_bridge.dart:232-254`; `packages/core_sync/lib/src/projection.dart:20-22` | Чужой `GroupCreated` принимается `core_sync` от любого подписанта; bridge молча ставит `_fatalError` и навсегда останавливает `_refresh`, не публикуя ошибку в `watch()`. Рабочая группа замирает, restore блокируется — удалённый DoS по groupId. | blocker; не принимать чужие корни на ingest или явно сигналить конфликт в UI и давать repair/delete. |
| G-14 | `packages/core_group/lib/src/group_sync_bridge.dart:71-100`; `packages/core_group/lib/src/group_lifecycle.dart:210-215` | `start()` не exception-safe: исключение из `registerGroup`/`signer.verify`/`allEvents` оставляет `_started=true` без подписки, повторный `start()` возвращает `Ok`, исключения выходят наружу вместо `Result`. | major; try/catch, сброс `_started`, `_fatalError` и `Err`. |
| G-15 | `packages/core_group/lib/src/group_sync_bridge.dart:191-229`; `packages/core_storage/lib/src/group_metadata_store_impl.dart:64-77` | Для `origin.created` проверяется только `author == owner`, но не `author == localAuthor`; метаданные не аутентифицированы. Подмена локальной БД позволяет подложить валидно подписанный чужим ключом genesis с тем же `groupId`, и `open()` покажет атакующего владельцем. | major; требовать `authorId == localAuthor` для created; аутентифицировать метаданные. |
| G-16 | `packages/core_group/lib/src/group_sync_bridge.dart:312-326`; `packages/core_group/lib/src/group_lifecycle.dart:324-328` | `create()` не нормализует `initialMembers` и не валидирует draft до `createEvent`: набор без owner или пустой `name` создаёт genesis, который новая валидация отвергает, pending-метаданные остаются навсегда. | major; валидировать draft до записи, всегда добавлять owner, чистить genesis/метаданные при ошибке. |
| G-17 | `packages/core_group/lib/src/group_lifecycle.dart:219-235,300-334`; `packages/core_storage/lib/src/group_metadata_store_impl.dart:48-57` | Одна невалидная/двойная pending-группа блокирует загрузку всех: `recoverPendingGroups` обрывается, `loadActiveGroup` падает. `list()` не сверяет `row.group_id` с JSON, в отличие от `load()`. | major; изолировать ошибки по группам, карантинить невалидные pending, проверять `group_id` в `list()`. |
| G-18 | `packages/core_group/lib/src/invite_link.dart:55-108`; `packages/core_group/lib/src/group_lifecycle.dart:147-183,207` | Корень инвайта не аутентифицирован: нет подписи инвайтера над `(gid, gen, iid, срок)`, `inviterId` не проверяется и не сохраняется; `gen` принимается любой непустой строкой, группа активируется до проверки. Подмена ссылки навязывает корень, битый `gen` даёт вечный `GenesisConflict`. | major; подпись инвайтера, `gen` как 64-hex, не активировать до валидации, предусмотреть delete/repair. |
| G-19 | `packages/core_group/lib/src/group_sync_bridge.dart:89-100,232-254` | Гонка подписки: `changes.listen` ставится после первичного `_refresh`, событие между `allEvents` и `listen` теряется до следующего изменения. Invite-путь не перепроверяет genesis при его появлении: при не-permanent отказе `apply` мост остаётся started с пустым состоянием. | minor; подписаться до refresh и повторить refresh; при появлении ожидаемого `genesisId` прогонять `_validateGenesis`, отказ применения считать фатальным. |
| G-20 | `packages/core_group/lib/src/group_sync_bridge.dart:191-229` | Payload декадируется в protobuf до проверки `id == SHA-256(canonical)` и Ed25519. Применения нет, но недоверенные данные разбираются раньше криптопроверки. | minor; сначала id и подпись, затем `_codec.decode`. |

## Принятые ограничения

- Android: root-доступ компрометирует хранилище; StrongBox не гарантирован; ключи
  Keystore не восстанавливаются при переносе на новое устройство.
- Linux: защита ограничена правами пользователя и наличием Secret Service; root и
  тот же пользователь не блокируются.
- Web: XSS и отсутствие аппаратной изоляции не защищаются; персистентность зависит
  от `storage.persist()`.
- Ни одна платформа не защищает от компрометации самого устройства.
