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

R-01…R-09 закрыты 2026-10-25 (аутентификация первого хопа, LRU-лимиты,
единый размер, token bucket до парсинга, unknown-поля, seen/in-flight,
MemberRelay, relay-тег и opt-in default). Дополнительно 2026-10-25:
Ed25519-подпись origin, `originTtl = ttl + hopCount`, подписанный nonce(16),
отдельный `PeerChannels.relay` и `Transport.relayIncoming/sendRelay`;
`RelayEnvelope` v3.
Остаточные пункты:

| id | Место | Риск | Проверка / статус |
|----|-------|------|-------------------|
| R-10 | `packages/core_relay/lib/src/relay_transport.dart:241-277` | `accept` пробует один `nextHop`; при сбое `topology.remove(nextHop)` может удалить валидный presence получателя. | minor; перебирать альтернативы, удалять только relay-роль. |
| R-11 | `packages/core_relay/lib/src/relay_topology.dart:46-47,94-102,105-107` | `applyPresence` перезаписывает запись без сравнения `updatedAt`; старый анонс или `at` в будущем меняет маршруты. | minor; монотонность и ограничение будущих меток (подпись presence закрыта в Q37). |
| R-12 | `packages/core_relay/lib/src/relay_transport.dart:85-88,212-219,280-300` | Broadcast `incoming` теряет кадры до подписки при уже увеличенном `delivered`; синтетическое `'closed'` вне контракта; `close()` не закрывает `direct`. | minor; определить владение, буферизацию и события. |
| R-13 | `packages/core_relay/pubspec.yaml:15`; `relay_transport.dart:7` | Для не-security fingerprint используется `package:crypto`, формально расходится с hard rule `package:cryptography`. | minor; заменить или локально задокументировать. |
| R-14 | `packages/core_relay/lib/src/relay_transport.dart:90,302-315` | `_seen` защищает только 5 минут; после TTL повтор доставляется. Nonce входит в ключ, но окно не расширяет. Для group-sync покрыто sync-дедупом, для прочих payload контракт не зафиксирован. | minor; персистентный replay-window или явная документация. |
| R-15 | `packages/core_relay/test/relay_test.dart:241,255`; `packages/core_relay/DESIGN.md:25-26`; `docs/DESIGN.md:50` | Проверка непрозрачности тавтологична; нет тестов oversize/burst/malformed/close/source-disabled/dedupe-after-failure; DESIGN расходится с порядком проверок. | minor; усилить тесты и синхронизировать DESIGN. |

## Группы и DI (ревью 2026-10-25)

G-01…G-08 и G-12…G-24 закрыты, их история — в `git log`. Открыты только
G-09…G-11 из повторного ревью 2026-10-25.

| id | Место | Риск | Проверка / статус |
|----|-------|------|-------------------|
| G-09 | `packages/core_group/test/support/fake_sync.dart:30`; `packages/core_group/test/group_event_codec_test.dart:134`; `packages/core_group/test/group_sync_bridge_test.dart:200` | Fake-подпись forgeable, `prevId` проверяется только на непустоту, «идемпотентный start» уходит в early return; не покрыты конфликт после start, publish после `_fatalError`, исключение в start, невалидный/двойной pending, очистка активной группы, негативный invite после старта. | minor; Ed25519 signer, точные утверждения и provider-тесты. |
| G-10 | `packages/core_group/lib/src/group_event_codec.dart:484-486` | Пустой `inviteMode` декодируется как `InviteMode.open`, превращая malformed payload в open-инвайт. | minor; пустое значение — `MalformedGroupEvent`, добавить тест. |
| G-11 | `packages/core_group/lib/src/group_state.dart:782` | Исключение из `InviteProofVerifier.verify` выходит из `apply` вместо `Err(InvalidInviteProof)`. | minor; try/catch и тест с throw-verifier. |

## Принятые ограничения

- Android: root-доступ компрометирует хранилище; StrongBox не гарантирован; ключи
  Keystore не восстанавливаются при переносе на новое устройство.
- Linux: защита ограничена правами пользователя и наличием Secret Service; root и
  тот же пользователь не блокируются.
- Web: XSS и отсутствие аппаратной изоляции не защищаются; персистентность зависит
  от `storage.persist()`.
- Ни одна платформа не защищает от компрометации самого устройства.
