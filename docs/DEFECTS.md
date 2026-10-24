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

## Принятые ограничения

- Android: root-доступ компрометирует хранилище; StrongBox не гарантирован; ключи
  Keystore не восстанавливаются при переносе на новое устройство.
- Linux: защита ограничена правами пользователя и наличием Secret Service; root и
  тот же пользователь не блокируются.
- Web: XSS и отсутствие аппаратной изоляции не защищаются; персистентность зависит
  от `storage.persist()`.
- Ни одна платформа не защищает от компрометации самого устройства.
