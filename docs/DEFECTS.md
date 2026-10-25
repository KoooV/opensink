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
MemberRelay, relay-тег и opt-in только для forwarding). Дополнительно 2026-10-25:
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
Повторное ревью 2026-10-25 (reviewer+crypto) блокеров не нашло; остаточные
R-16–R-27 закрыты в пакете `core_relay`:

- R-16/R-20/R-21/R-25: буфер `incoming` не очищается до фактической доставки,
  `.first` не теряет остальные кадры; `delivered`/`queuedInbound` разделены;
  переполнение, отключённый буфер и закрытие потока считаются отдельными
  счётчиками; после отмены последнего слушателя буфер снова активен. Тесты:
  `.first`, порядок нескольких кадров, cancel→frames→relisten, close с
  неотданными кадрами.
- R-17/R-18: `deliver`/`accept` повторно проверяют `_closed` после каждого
  `await` до мутаций; shutdown мемоизирован, `direct` закрывается ровно один
  раз, в том числе после `_onDirectDone`.
- R-19: остаётся задокументированным at-least-once контрактом: после `seenTtl`
  идущий выше слой обязан дедуплицировать payload по своему идентификатору.
- R-22/R-23/R-24: при полном `seen` новые кадры отбрасываются
  (`droppedSeenFull`), неистёкшие nonce не вытесняются; TTL считается по
  монотонным часам, wall-clock остаётся для token bucket; ошибки не-awaited
  `accept` учитываются в `acceptFailed`.
- R-26/R-27: добавлены тесты overflow без `_remember`, `incomingBufferFrames: 0`,
  двойного close/close во время in-flight `accept`, проброса `onError` из
  `direct.events`; auth-тесты реального Ed25519 (tamper/replay/dup), реестр
  `TestSigner` очищается в `setUp`, сравнение подписи constant-time.

## Группы и DI (ревью 2026-10-25)

G-01…G-08 и G-12…G-24 закрыты, их история — в `git log`. Открыты только
G-09…G-11 из повторного ревью 2026-10-25.

| id | Место | Риск | Проверка / статус |
|----|-------|------|-------------------|
| G-09 | `packages/core_group/test/support/fake_sync.dart:30`; `packages/core_group/test/group_event_codec_test.dart:134`; `packages/core_group/test/group_sync_bridge_test.dart:200` | Fake-подпись forgeable, `prevId` проверяется только на непустоту, «идемпотентный start» уходит в early return; не покрыты конфликт после start, publish после `_fatalError`, исключение в start, невалидный/двойной pending, очистка активной группы, негативный invite после старта. | minor; Ed25519 signer, точные утверждения и provider-тесты. |
| G-10 | `packages/core_group/lib/src/group_event_codec.dart:484-486` | Пустой `inviteMode` декодируется как `InviteMode.open`, превращая malformed payload в open-инвайт. | minor; пустое значение — `MalformedGroupEvent`, добавить тест. |
| G-11 | `packages/core_group/lib/src/group_state.dart:782` | Исключение из `InviteProofVerifier.verify` выходит из `apply` вместо `Err(InvalidInviteProof)`. | minor; try/catch и тест с throw-verifier. |

## Sender keys (ревью 2026-10-25)

Блокеров нет; production `SenderKeyChannel` ещё не подключён, поэтому пункты ниже
остаются latent. Текущие подпись, domain separation и verify-before-use признаны
корректными.

| id | Место | Риск | Проверка / статус |
|----|-------|------|-------------------|
| G-25 | `packages/core_group/lib/src/key_distributor.dart:79,656` | Карантин пишется по `id` без содержимого/подписи: пакет с тем же `(groupId, epoch, sender, recipient)`, но битой подписью или пустым `keyPackage`, перезаписывает `verified`/`pending`/`delivered`. | high, latent; ключ карантина с content-hash, запрет перезаписи `verified`, тест same-id. |
| G-26 | `packages/core_group/lib/src/key_distributor.dart:538,563` | `retryPending` не валидирует и не переподписывает legacy pending; pending без подписи навсегда отклоняется `E2eSenderKeyDelivery`, delivered без подписи блокирует повтор через `_isDelivered`. | high, latent; переподпись/валидация при retry либо инвалидация legacy pending/delivered. |
| G-27 | `packages/core_group/lib/src/key_distributor.dart:627`; `apps/app/lib/group/sender_key_verifier.dart:18` | Подпись подтверждает владение ключом из `sender`, но не членство отправителя в группе и не авторизованность эпохи; при подключении `receive` не-участник сможет попасть в `verified`. | medium, latent; проверять `sender ∈ GroupState.members` и эпоху до сохранения, негативный тест. |
| G-28 | `packages/core_group/lib/src/key_distributor.dart:551`; `packages/core_group/lib/src/group_controller.dart:224` | `GroupKeyRotation.signature` не заполняется production-вызовом `_distribute`, поэтому удалённая ротация с непустым `keyPackage` уходит в карантин `missing signature`. | medium, latent; прокинуть подписанный пакет через `apply`/`_distribute` или убрать ветку. |
| G-29 | `packages/core_group/lib/src/sender_key_package_codec.dart:37` | `utf8.decode`/`jsonDecode`/`base64Decode` до проверки размера; `maxPackageBytes` ограничивает только `keyPackage` после decode, большой payload даёт memory/CPU DoS. | medium, latent; лимит `data.length` до декодирования. |
| G-30 | `packages/core_group/lib/src/key_distributor.dart:114` | `copyWith` сохраняет старую `signature` при изменении подписываемых полей; получается «выглядящий подписанным» пакет с невалидной подписью. | low, latent; сбрасывать подпись при изменении полей или убрать `copyWith`. |
| G-31 | `packages/core_group/lib/src/key_distributor.dart:610,640` | `$error` интерполируется в `lastError` и персистентный `reason` карантина; исключение `Signer`/verifier может унести ключевой материал в secure store/логи. | low, latent; фиксированные коды причин без `toString()` ошибки. |
| G-32 | `packages/core_group/lib/src/key_distributor.dart:423,479` | Нет монотонности/отбора по эпохе в `receive`/`restore`: старый валидно подписанный пакет может лежать в `verified` рядом с новым, выбор ключа станет order-dependent. | low, latent; максимальная эпоха на отправителя, сортировка `restore`. |
| G-33 | `apps/app/test/di/group_providers_test.dart:62` | `FakeSigner()` даёт не-hex подпись, `localUser: 'test-user'` не 32-байтный hex; path self-verify не подписывает, тест этого не замечает. | low, latent; валидный 32-байтный userId, hex-fake, проверка `lastError`/подписи. |
| G-34 | `packages/core_group/test/sender_key_signing_test.dart`; `apps/app/test/di/group_providers_test.dart` | Нет негативных тестов `SenderKeyPackageCodec.decode`, миграции legacy, same-id вытеснения `verified`, не-участника, domain/replay и проверки реальным `CryptoSigner`; fake signer дублируется. | medium, latent; добавить перечисленные кейсы и общий fake. |
| G-35 | `docs/OPEN_QUESTIONS.md:241`; `packages/core_group/DESIGN.md:128` | Docs обещают перевыпуск legacy, но не описывают миграцию pending/delivered; поля подписи перечислены без `senderKeyPackageSigningDomain`; контракт `GroupKeyRotation.signature` вводит в заблуждение. | low, документирован; синхронизировать docs с кодом и миграцией. |

## Принятые ограничения

- Android: root-доступ компрометирует хранилище; StrongBox не гарантирован; ключи
  Keystore не восстанавливаются при переносе на новое устройство.
- Linux: защита ограничена правами пользователя и наличием Secret Service; root и
  тот же пользователь не блокируются.
- Web: XSS и отсутствие аппаратной изоляции не защищаются; персистентность зависит
  от `storage.persist()`.
- Ни одна платформа не защищает от компрометации самого устройства.
