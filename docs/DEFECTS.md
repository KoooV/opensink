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

R-01…R-11 закрыты 2026-10-25 (аутентификация первого хопа, LRU-лимиты,
единый размер, token bucket до парсинга, unknown-поля, seen/in-flight,
MemberRelay, relay-тег и opt-in default). Дополнительно 2026-10-25:
Ed25519-подпись origin, `originTtl = ttl + hopCount`, подписанный nonce(16),
отдельный `PeerChannels.relay` и `Transport.relayIncoming/sendRelay`;
`RelayEnvelope` v3. R-10: `accept`/`deliver` перебирают альтернативы, сбой
снимает только relay-роль (`disableRelay`), presence сохраняется; исчерпание
альтернатив в `accept` считается в `forwardExhausted`. R-11: presence
применяется только при более новом `updatedAt`, будущие метки ограничены
временем получения, `announce` копирует `neighbors`. R-12…R-15 закрыты:
ограниченный буфер `incoming`, владение `direct` и закрытие потоков без
синтетического `'closed'`, fingerprint через `package:cryptography`,
документированное окно seen-кэша, тесты burst/malformed/close/opt-out/dedupe.
Повторное ревью 2026-10-25 (reviewer+crypto) блокеров не нашло, но выявило
остаточные пункты:

| id | Место | Риск | Проверка / статус |
|----|-------|------|-------------------|
| R-16 | `packages/core_relay/lib/src/relay_transport.dart:429-440` | `_flushBufferedInbound` очищает буфер до фактической доставки; при `.first`/ранней отмене подписчика остальные кадры теряются, хотя уже помечены seen. | medium; не очищать до доставки или возвращать неотданное в `onCancel`; тест с 2–3 кадрами и `.first`. |
| R-17 | `packages/core_relay/lib/src/relay_transport.dart:153-225,232-370` | `deliver`/`accept` проверяют `_closed` только на входе и продолжают после `await`: возможны отправка, мутации topology/метрик и `noRoute`/`disabled` вместо `closed` после shutdown. | medium; повторять проверку `_closed` после каждого `await` до мутаций. |
| R-18 | `packages/core_relay/lib/src/relay_transport.dart:373-409`; `packages/core_relay/DESIGN.md:41-43` | Нет мемоизации shutdown: `close()` после `_onDirectDone` не ждёт завершения и не закрывает `direct`, хотя DESIGN заявляет владение. | low; мемоизировать `Future<void>? _closing`, закрывать `direct` ровно один раз. |
| R-19 | `packages/core_relay/lib/src/relay_config.dart:45-50`; `relay_transport.dart:49-53,286-291,479-485` | После `seenTtl` тот же подписанный кадр снова принимается; `RelayInbound` не отдаёт nonce/frameId, поэтому верхний слой не может дедуплицировать произвольный payload. | документирован; at-least-once на уровне relay, обязательный idempotency-key в payload выше. |
| R-20 | `packages/core_relay/lib/src/relay_transport.dart:299-310,384`; `packages/core_relay/DESIGN.md:36-37` | `delivered` и `_remember` срабатывают при постановке в буфер, а `close()` очищает буфер; счётчик учитывает кадр, не полученный подписчиком. | medium; разделить queued/delivered или поправить DESIGN. |
| R-21 | `packages/core_relay/lib/src/relay_transport.dart:412-424` | `droppedInboundOverflow` растёт при отключённом буфере (`incomingBufferFrames <= 0`) и гонке с `close()`, поэтому не означает только переполнение. | low; отдельные счётчики или не инкрементить в этих ветках. |
| R-22 | `packages/core_relay/lib/src/relay_transport.dart:472-474` | При заполнении `seenMaxEntries` запись вытесняется до истечения `seenTtl`; валидными кадрами можно вытеснить nonce и повторить кадр в пределах окна. | low; не вытеснять неистёкшие записи или отбрасывать новый кадр; тест eviction+replay. |
| R-23 | `packages/core_relay/lib/src/relay_transport.dart:72,479-485` | TTL seen-кэша считается по `DateTime.now`: скачок часов сокращает или растягивает replay-окно. | low; монотонное время для TTL, wall-clock оставить presence. |
| R-24 | `packages/core_relay/lib/src/relay_transport.dart:86,286,493-498` | Асинхронный `_frameKey` может бросить исключение, а `accept` запускается через `unawaited`; ошибка остаётся необработанной и без метрики. | low; `try/catch` с метрикой или синхронный fingerprint. |
| R-25 | `packages/core_relay/lib/src/relay_config.dart:55-57`; `relay_transport.dart:416-426` | Документация говорит «до первой подписки», но после отмены последнего слушателя буфер включается снова; нет теста cancel→кадры→relisten. | low; уточнить «пока нет слушателей» и добавить тест. |
| R-26 | `packages/core_relay/test/relay_test.dart:1366-1655` | Нет тестов на несколько кадров и порядок, повторную подписку, overflow без `_remember`, `incomingBufferFrames: 0`, двойной `close()`/close во время in-flight `accept`, проброс `onError` из `direct.events`. | low; добавить перечисленные кейсы. |
| R-27 | `packages/core_relay/test/relay_test.dart:43-70` | `TestSigner` использует XOR и сравнение `==`; большинство auth-тестов не идут через Ed25519. | info; real-`CryptoSigner` тесты на tamper/replay/dup и очистка registry. |

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
