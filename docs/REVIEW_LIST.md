# Карта ручного ревью

Список актуален для текущего состояния `core_crypto`, `core_protocol`, `core_storage`,
`core_signaling`, `core_peer`, `core_sync` и `platform_*`. Проверяется поведение и
инварианты, а не история исправлений.

## 1. Identity, подпись, BIP-39

| Файл | Что проверять |
|------|---------------|
| `packages/core_crypto/lib/src/bip39.dart` | Встроенный wordlist, SHA-256 на Dart, PBKDF2-HMAC-SHA-512 (2048 итераций, соль `"mnemonic" + passphrase`), отказ от не-ASCII passphrase, проверка checksum. |
| `packages/core_crypto/lib/src/identity.dart` | Публичные Ed25519/X25519-ключи выводятся из того же seed, что и приватные; `verifyBinding()`; `toString()` не раскрывает секреты. |
| `packages/core_crypto/lib/src/signer.dart` | `sign()` использует пару из одного seed; `verify()` возвращает `false` на некорректный ввод и не бросает наружу. |

## 2. AEAD и HKDF

| Файл | Что проверять |
|------|---------------|
| `packages/core_crypto/lib/src/aead.dart` | XChaCha20-Poly1305, nonce 24, ключ 32, MAC 16; wire-формат `nonce || ciphertext || mac`; проверка минимальной длины; поддержка AAD; единая ошибка `DecryptionFailed`. |
| `packages/core_crypto/lib/src/hkdf.dart` | Домены `GroupKeyContext`, разделение вывода; отсутствие переиспользования `info`. |
| `packages/core_crypto/lib/src/group_secret.dart` | Детерминизм ключей, разные контексты дают разные ключи, секреты не попадают в `toString()`. |

## 3. E2EE

| Файл | Что проверять |
|------|---------------|
| `packages/core_crypto/lib/src/e2ee/x3dh.dart` | Вариант без OPK; привязка SPK подписью Ed25519; `sender()` возвращает типизированную ошибку, а не исключение. |
| `packages/core_crypto/lib/src/e2ee/double_ratchet.dart` | DH-шаг, KDF_RK/KDF_CK, отдельные message/chain ключи, `maxSkip = 100`, TTL 24 ч, лимит `messageNumber = 2^30`, атомарность при ошибке AEAD, replay-защита, сериализация v1. |
| `packages/core_crypto/lib/src/e2ee/sender_keys.dart` | Подпись проверяется до расшифровки; окно replay по отправителю; ротация цепочки и ключа подписи; лимит `sequenceNumber = 2^30`. |
| `packages/core_crypto/lib/src/state_vault.dart` | `VaultResult` вместо исключений; случайный ключ хранилища; AAD привязан к kind/stateId/formatVersion; заголовок проверяется до расшифровки. |

## 4. SecureKeyStore

| Файл | Что проверять |
|------|---------------|
| `packages/core_domain/lib/src/interfaces/secure_key_store.dart` | Все методы возвращают `Result`; sealed `KeyStoreError`; секреты не в сообщениях ошибок. |
| `packages/core_crypto/lib/src/key_store/memory_secure_key_store.dart` | `@visibleForTesting`, отсутствие утечек в `toString()`, `IdentityNotFound` для отсутствующей записи. |
| `packages/platform_android/lib/src/secure_key_store_android.dart` | Keystore через `flutter_secure_storage`; версия схемы; маппинг исключений; исключение файлов из Auto Backup. |
| `packages/platform_linux/lib/src/secure_key_store_linux.dart` | libsecret/secret-service; probe-запись; `StoreUnavailable` без отката на открытый файл. |
| `packages/platform_web/lib/src/secure_key_store_web.dart` | `package:web` + `dart:js_interop`; AES-GCM-256 KEK с `extractable: false`; AAD = имя ключа; `requestPersistentStorage()`. |

## 5. Протокол

| Файл | Что проверять |
|------|---------------|
| `packages/core_protocol/lib/src/envelope.dart` | Поля 1–6; `signatureData()` покрывает поля 1–4 и payload; `unknownFields` не входят в подпись. |
| `packages/core_protocol/lib/src/codec.dart` | `Result`-ошибки, проверка лимитов, `sign`/`verify`, `decodePayload`, `isProcessable`. |
| `packages/core_protocol/lib/src/limits.dart` | Лимиты конверта, payload, чанка, строк, повторов, подписи. |
| `packages/core_protocol/lib/src/wire.dart` | Varint/fixed без 32-битного усечения; regression-тесты для значений > 32 бит. |
| `packages/core_protocol/lib/src/messages.dart` | 10 типов сообщений, стабильные номера полей, обратная совместимость. |

## 6. Хранение

| Файл | Что проверять |
|------|---------------|
| `packages/core_domain/lib/src/interfaces/event_store.dart` | `EventRecord.author` обязателен, `channelId` опционален, `InsertOutcome`, типизированные ошибки. |
| `packages/core_storage/lib/src/event_store_impl.dart` | Валидация `id`/`author`/payload, отсутствие записи при ошибке, replay/cursor без гонки, передача `channelId`. |
| `packages/core_storage/lib/src/database/schema.dart` | Схема v7, `pending_events`, индексы `idx_events_*`, append-only триггеры, миграции v1→v7. |
| `packages/core_storage/lib/src/database/app_database.dart` | Проверка версии SQLite при открытии, детерминированный порядок `(hlc, id)`, `rangeSummary` с SHA-256, пагинация `pageSize + 1`. |
| `packages/platform_linux/lib/src/storage_database_factory.dart` | `NativeDatabase.createInBackground`/`memory`, PRAGMA, `ResourceMissing` для отсутствующей `libsqlite3.so`. |
| `packages/platform_android/lib/src/storage_database_factory.dart` | Bundled SQLite, отсутствие тихого отката в memory. |
| `packages/platform_web/lib/src/storage_database_factory_web.dart` | Проверка MIME `sqlite3.wasm`/`drift_worker.js`, `WasmDatabase`, маппинг `WasmStorageImplementation` в `StorageInfo`. |
| `packages/core_storage/lib/src/retention.dart` | `deleteBlob` до удаления metadata; metadata сохраняется при ошибке callback. |

## 7. Signaling

| Файл | Что проверять |
|------|---------------|
| `packages/core_signaling/lib/src/secure_signaling_codec.dart` | Шифрование/аутентификация пакетов, `GroupSecret`, AAD с topic, replay/rate limit, типизированный отказ. |
| `packages/core_signaling/lib/src/nostr_signaling.dart` | NIP-01, ephemeral kind, BIP-340, формат конверта, reconnect/health. |
| `packages/core_signaling/lib/src/tracker_signaling.dart` | WebTorrent announce/offer/answer, формат `sdp`, пул трекеров. |
| `packages/core_signaling/lib/src/signaling_pool.dart` | Изоляция отказа реле, дедупликация по `(topic, kind, from, recipient, body)`, health. |
| `packages/core_signaling/lib/src/websocket_pool.dart` | Backoff, reconnect, ограничение очереди. |

## 8. Peer (WebRTC)

| Файл | Что проверять |
|------|---------------|
| `packages/core_peer/lib/src/peer_link.dart` | Perfect negotiation, polite/impolite, каналы, backpressure, ICE restart, reconnect, закрытие, отсутствие busy-loop. |
| `packages/core_peer/lib/src/transport.dart` | Прямой путь и relay, лимит ссылок, приоритеты, события состояния. |
| `packages/core_peer/lib/src/config.dart` | STUN-дефолты, таймауты, лимиты. |
| `packages/core_peer/lib/src/rtc/flutter_rtc.dart` | Только Flutter-адаптер; не должен попадать в чистый `core_peer.dart`. |

## 9. Синхронизация

| Файл | Что проверять |
|------|---------------|
| `packages/core_sync/lib/src/hlc.dart`, `hlc_validator.dart` | Монотонность, `observe`, ограничение будущих меток. |
| `packages/core_sync/lib/src/sync_event.dart` | Канонический protobuf, домены id/подписи, `prevId`, лимит 512 KiB. |
| `packages/core_sync/lib/src/ingest_pipeline.dart` | Порядок размер → id → подпись → membership → prev → дедуп → запись; pending для неизвестного автора. |
| `packages/core_sync/lib/src/projection.dart` | Membership по `(HLC, id)` строго до события, tombstones только автором. |
| `packages/core_sync/lib/src/frame.dart` | Кадры summary/range/window/events/gossip/ping, лимиты, курсор `(hlc, id)`. |
| `packages/core_sync/lib/src/sync_engine_impl.dart` | High/low lanes, одна страница на диапазон, LRU, `hops ≤ 4`, token bucket, `drain`. |

## 10. DI и приложение

| Файл | Что проверять |
|------|---------------|
| `apps/app/lib/di/providers.dart` | Реальные storage/sync/identity; fakes только для несвязанных портов; корректный dispose. |
| `apps/app/lib/di/secure_key_store_platform.dart`, `storage_backend_platform.dart` | Conditional imports; на каждой платформе выбирается рабочая реализация. |

## Критерий прохождения ревью

- Каждый пункт проверяется человеком независимо.
- Новые расхождения фиксируются в `docs/DEFECTS.md` или `docs/OPEN_QUESTIONS.md`.
- Изменения кода в рамках ревью не вносятся без отдельного решения о расширении
  скоупа.
