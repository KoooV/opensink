# REVIEW_LIST.md — файлы и диапазоны для ручного ревью (слои 2 и 4)

Каждая запись: файл:диапазон, что проверять, критерий прохождения.

---

## 1. Подпись и деривация ключей из мнемоники

| Файл | Диапазон | Что проверять |
|------|----------|---------------|
| `packages/core_crypto/lib/src/bip39.dart` | 1–296 | Встроенный wordlist 2048 слов, SHA-256 на чистом Dart, PBKDF2-HMAC-SHA-512 (2048 итераций, соль `"mnemonic" + passphrase`), отказ от не-ASCII passphrase (`ArgumentError`), `mnemonicToEntropy` / `entropyToMnemonic` валидация checksum. |
| `packages/core_crypto/lib/src/identity.dart` | 1–173 | `recoverIdentityFromMnemonic()` использует `Ed25519().newKeyPairFromSeed(edMaterial)` и `X25519().newKeyPairFromSeed(xMaterial)` (публичные ключи из тех же seed, что и приватные — исправление D-03), `verifyBinding()` — подпись X25519 public key Ed25519 private key, `toString()` не раскрывает секреты. |
| `packages/core_crypto/lib/src/signer.dart` | 1–53 | `sign()` использует пару из одной пары (исправление D-02), `verify()` ловит все `Exception`/`Error` → `false` на некорректный ввод, нет временной ключевой пары с подменой public key. |

---

## 2. AEAD-обёртка

| Файл | Диапазон | Что проверять |
|------|----------|---------------|
| `packages/core_crypto/lib/src/aead.dart` | 1–93 | `XChaCha20Poly1305Aead` (не `AesGcm` — исправление D-01), wire format `nonce(24) || ciphertext || mac(16)`, `generateAeadKey()` на XChaCha20, `decrypt` проверяет min length 40 байт, единый `DecryptionFailed` без раскрытия причины, поддержка AAD. |
| `packages/core_crypto/test/aead_test.dart` | все | Тестовые векторы draft-arciszewski-xchacha-03 пример #1, roundtrip размеров 0/1/16/1 МБ, порча nonce/тела/MAC, неверный ключ, детерминизм при фиксированном nonce. |

---

## 3. X3DH

| Файл | Диапазон | Что проверять |
|------|----------|---------------|
| `packages/core_crypto/lib/src/e2ee/x3dh.dart` | 1–268 | Ослабленный вариант без OPK, контекст подписи `"opensink/x3dh/spk-binding/v1|" + spkBytes`, `sender()` возвращает `CryptoResult` с `Err(InvalidSignature)` при неверной привязке, `receiver()` с локальным бандлом, `ed25519PublicKey` в бандле. |
| `packages/core_crypto/test/e2ee/x3dh_test.dart` | все | RFC 7748 §6.1 вектор, roundtrip sender/receiver, разные бандлы → разные ключи, неверная подпись SPK → отказ, отсутствие подписи → отказ, без OPK. |
| `packages/core_crypto/test/x3dh_independent_test.dart` | все | Независимый пересчёт SK, коммутативность DH, негативы (перестановка dh2||dh3, замена info, подмена SPK, подмена ed25519PublicKey). |

---

## 4. Double Ratchet

| Файл | Диапазон | Что проверять |
|------|----------|---------------|
| `packages/core_crypto/lib/src/e2ee/double_ratchet.dart` | 1–628 | `dhRatchetStep()` реализован (не UnimplementedError — исправление D-06), KDF_RK (HKDF-SHA-256, salt=prev rootKey, info=`"opensink/double-ratchet/root-key"`), KDF_CK один вызов HKDF outputLength 64 → split messageKey/nextChainKey (исправление D-18), `remoteDhPublicKey` из опционального поля при `hasOptionalDh` (исправление D-16), атомарность `skippedKeys` (исправление D-17), `_maxMessageNumber = 1 << 30` (исправление D-19), `maxSkip = 100` FIFO + TTL 24ч, header v1 формат, `toBytes`/`fromBytes` версии 1. |
| `packages/core_crypto/test/e2ee/double_ratchet_test.dart` | все | Ping-pong, out-of-order, потерянное сообщение, MAX_SKIP превышение, replay, порча шифртекста/заголовка, dhRatchetStep ключи меняются, сериализация v1, неизвестная версия → ошибка, отсутствие секретов в toString, атомарность (toBytes идентичен после неудачного decrypt), DoS на огромные messageNumber, forward secrecy (message key не в serialize), post-compromise. |

---

## 5. Sender Keys (группы)

| Файл | Диапазон | Что проверять |
|------|----------|---------------|
| `packages/core_crypto/lib/src/e2ee/sender_keys.dart` | 1–312 | `SenderKey`: chainKey + Ed25519 signingKeyPair + sequenceNumber + groupId + senderPeerId, encrypt: KDF_CK + AEAD + подпись (ciphertext || header), decrypt: подпись первой, затем расшифровка, rotate: новая цепочка + новая пара подписи, replay protection окно 100 по senderPeerId. |
| `packages/core_crypto/test/e2ee/sender_keys_test.dart` | все | Roundtrip с подписью, продвижение итерации, неверная итерация → отказ, подменённая подпись → отказ, порча шифртекста → отказ, rotate, старый ключ не читает новые, новый участник не читает прошлое, replay protection, keyFor/withKey, атомарность. |

---

## 6. StateVault (защита состояний при хранении, F5)

| Файл | Диапазон | Что проверять |
|------|----------|---------------|
| `packages/core_crypto/lib/src/state_vault.dart` | 1–279 | `seal`/`open` возвращают `VaultResult<T>` (sealed classes, без исключений), ключ хранилища — случайный 256-битный в `SecureKeyStore` (не из identity seed), конверт v1: `version(1) || kind(1) || stateIdLen(2 LE) || stateId || nonce(24) || ciphertext || mac(16)`, AAD: `utf8("opensink/state/v1") || kind || stateIdLen || stateId || formatVersion`, `open()` проверяет заголовок конвента перед расшифровкой, `toString()` не раскрывает секреты. |
| `packages/core_crypto/test/state_vault_test.dart` | все | 20 тестов: roundtrip, разные seal → разные шифртексты, негативы (kind/stateId/formatVersion), порча каждой зоны конвента, отсутствие ключей цепочки в выводе, два хранилища с разными ключами не открывают конвенты друг друга, восстановление DoubleRatchet и SenderKeyState через open. |

---

## 7. Платформенные хранилища (SecureKeyStore)

| Файл | Диапазон | Что проверять |
|------|----------|---------------|
| `packages/core_domain/lib/src/interfaces/secure_key_store.dart` | 1–148 | Все методы возвращают `Result<T, KeyStoreError>`, `KeyStoreError` sealed: `IdentityNotFound`, `StoreError`, `StoreUnavailable`, `StoreCorrupted`, `StoreAccessDenied`, секреты не в сообщениях ошибок. |
| `packages/core_crypto/lib/src/key_store/memory_secure_key_store.dart` | все | `@visibleForTesting`, хранит verbatim (по D-04 by design), `loadIdentity` отсутствие → `Err(IdentityNotFound)`, `toString()` не раскрывает `privateSeed`. |
| `packages/platform_android/lib/src/secure_key_store_android.dart` | 1–170 | flutter_secure_storage → Keystore (v9.2.4), `privateSeed` как base64 в JSON, ключ `opensink_identity_v1:<userId>`, `schemaVersion` проверка → `StoreCorrupted`, маппинг исключений плагина в `KeyStoreError`, авто-бэкап исключение файлов. |
| `packages/platform_linux/lib/src/secure_key_store_linux.dart` | 1–220 | flutter_secure_storage → libsecret/secret-service, `checkDependencies()` probe-запись, `_stateKey` с префиксом `opensink_state_key_`, `StoreUnavailable` при отсутствии Secret Service без отката на файл в открытом виде. |
| `packages/platform_web/lib/src/secure_key_store_web.dart` | 1–520 | `package:web` (v0.5.1) + `dart:js_interop`, **нет `dart:html`**, алгоритмы Web Crypto получают явный `name: "AES-GCM"`, KEK: AES-GCM-256 `CryptoKey` `extractable: false` в IndexedDB, гонка вкладок в одной `readwrite` транзакции, AAD = имя ключа, `requestPersistentStorage()`, ошибки: `StoreUnavailable` / `StoreCorrupted` / `StoreError`. |
| `packages/core_domain/lib/src/interfaces/fakes.dart` | все | `FakeSecureKeyStore` реализует Result-контракт, все методы including `storeKey`/`loadKey`/`deleteKey`. |

---

## 8. Дополнительно: файлы с дефектами в истории

| Файл | Диапазон | Связанные дефекты |
|------|----------|-------------------|
| `packages/core_crypto/lib/src/e2ee/double_ratchet.dart` | 200–330 | D-16 (remoteDhPublicKey), D-17 (атомарность), D-18 (KDF_CK), D-19 (DoS messageNumber) |
| `packages/core_crypto/lib/src/e2ee/sender_keys.dart` | 200–230 | D-20 (DoS sequenceNumber) |
| `packages/core_crypto/lib/src/aead.dart` | все | D-01 (AES-GCM → XChaCha20) |
| `packages/core_crypto/lib/src/signer.dart` | все | D-02 (временная ключевая пара) |
| `packages/core_crypto/lib/src/identity.dart` | все | D-03 (публичные ключи не из приватных seed) |

---

## Критерий прохождения ревью

- Каждый пункт проверяется человеком независимо.
- Выявленные расхождения фиксируются в `docs/DEFECTS.md` как новые D-xx или комментируются как «по дизайну».
- Код не меняется в рамках фазы F6 без отдельного решения о расширении скоупа.

---

## 9. Слой 4: core_storage (drift, EventStore)

| Файл | Диапазон | Что проверять |
|------|----------|---------------|
| `packages/core_domain/lib/src/interfaces/event_store.dart` | 5–110 | `InsertOutcome` (`inserted`/`duplicate`), sealed `EventStoreWriteError`, обязательный `author` и опциональный `channelId` в `EventRecord`, `author` не извлекается из payload, курсор `watchFrom` — id события. |
| `packages/core_storage/lib/src/event_store_impl.dart` | 35–210 | `write` валидирует `id` (ASCII `[A-Za-z0-9._:-]`, 1–128), `author` (64 hex = 32 байта), `payload` (непустой, ≤ 1 МиБ); передаёт `channelId`; ошибки типизированы и не пишут в БД; `watchFrom`/`watchGroup` подписываются до replay и дедуплицируют по id; исключения executor-а → `StorageWriteError`. |
| `packages/core_storage/lib/src/database/app_database.dart` | 78–130 | `SELECT sqlite_version()` после `ensureOpen` и до схемы; минимум 3.24.0; `DatabaseVersionTooLow`/`OpenFailure`; версия в `StorageInfo`. |
| `packages/core_storage/lib/src/database/app_database.dart` | 139–220 | Чтение `schema_info`, создание схемы; миграции и запись версии одной транзакцией; поведение для будущей версии. |
| `packages/core_storage/lib/src/database/app_database.dart` | 310–520 | Детерминированный порядок `hlc/id`, `rangeSummary` с SHA-256 и `RangeTooLarge`, `batchEvents`; `eventsFromCursor` сравнивает `(hlc, id)`; `channelPage` использует `pageSize + 1` для точного `hasMore`. |
| `packages/core_storage/lib/src/database/app_database.dart` | 221–252 | `INSERT OR IGNORE INTO events`, `runUpdate`, `seq` не записывается, дубль не перезаписывает байты. |
| `packages/core_storage/lib/src/database/schema.dart` | 41–330 | `schemaVersion = 7`; DDL `events` без `seq`; индексы; миграции v1→v2, v2→v3, пустой v3→v4, v4→v5 с триггерами, v5→v6 с пересборкой `events`, v6→v7 с `pending_events`. |
| `packages/platform_linux/lib/src/storage_database_factory.dart` | 24–114 | `StorageBackend`, `NativeDatabase.createInBackground`/`memory`, PRAGMA `foreign_keys`/`WAL`/`FULL`, проверка имени, предупреждение temp-каталога, `ResourceMissing` для отсутствующей `libsqlite3.so`. |
| `packages/platform_android/lib/src/storage_database_factory.dart` | 23–103 | Те же контракты для Android; bundled SQLite из `sqlite3_flutter_libs`, отсутствие тихого отката в memory. |
| `packages/platform_web/lib/src/storage_database_factory_web.dart` | 1–160 | Проверка MIME `sqlite3.wasm`/`drift_worker.js`, `WasmDatabase.open`/`inMemory`, `InMemoryFileSystem`, маппинг `WasmStorageImplementation` → `StorageInfo`, предупреждения для `unsafeIndexedDb`/memory/missing features, `ResourceMissing`. |
| `packages/core_storage/lib/src/models/storage_info.dart` | 1–70 | `StorageSpec`/`StorageInfo`/`OpenedStorage`/`StorageBackend`, sealed `StorageOpenError`, неизменяемость `warnings`. |
| `packages/core_storage/lib/src/retention.dart` | все | `run` вызывает `deleteBlob` до удаления metadata; при ошибке metadata сохраняется; `expireBlobs` — metadata-only. |
| `packages/core_storage/lib/src/platform/storage_backend_result.dart` | 1–25 | `openResult` не выпускает исключения: известные ошибки сохраняются, остальные → `OpenFailure`. |
| `packages/core_storage/test/event_store_validation_test.dart` | все | Пустой/короткий/не-hex автор, пустой `id`, пустой и слишком большой payload; после ошибки записи нет. |
| `packages/core_storage/test/event_store_concurrency_test.dart` | все | Параллельные записи одного `id` в одной транзакции и из разных транзакций: ровно один `inserted`. |
| `packages/core_storage/test/sqlite_open_and_migration_test.dart` | 72–230 | Версия SQLite в `StorageInfo`, ошибка для 3.23.0, schema v7, миграции v3→v7 и v5→v6 с сохранением авторов/данных и удалением `seq`. |
| `packages/core_storage/test/index_query_plan_test.dart` | все | `EXPLAIN QUERY PLAN` использует `idx_events_group_hlc` и `idx_events_author_hlc`. |
| `packages/core_storage/test/event_store_contract.dart`, `portable_storage_suite.dart` | все | Общий контракт и 12-тестовый поведенческий набор, исполняемый native- и Chrome-раннерами. |
| `tool/fetch_web_assets.sh`, `tool/web_assets.lock`, `tool/web_assets.sha256` | все | Версии и SHA-256 `drift_worker.js`/`sqlite3.wasm`; ресурсы не хранятся в Git. |
| `tool/test_web_storage_chrome.sh` | все | Staging ресурсов, Chrome/dart2js, контракт, persistence, typed errors, perf budget. |

### Критерии прохождения ревью слоя 4

- `EventRecord.author` обязателен; хранилище не разбирает payload и не проверяет подпись.
- Дубль `id` не перезаписывает байты; колонка `seq` удалена в v6; порядок — `hlc`.
- Минимум SQLite 3.24.0 проверяется при каждом открытии; ошибки типизированы.
- Миграция v3→v7 не декодирует старые payload, сохраняет карантинные строки, создаёт append-only триггеры и `pending_events`; v5→v6 удаляет `seq` без потери событий.
- `UPDATE`/`DELETE` событий блокируются SQLite-триггерами; низкоуровневый `insertEvent` помечен `@internal`.
- `core_storage/lib` не содержит платформенных импортов; фабрики живут в `platform_*`.
- Web-деградация не приводит к тихому откату на memory; предупреждения попадают в `StorageInfo.warnings`.

---

## 10. Слой 7: core_sync (HLC, anti-entropy, gossip)

| Файл | Диапазон | Что проверять |
|------|----------|---------------|
| `packages/core_sync/lib/src/hlc.dart` | все | `Hlc(physicalMs, counter)`, лексикографическое сравнение, монотонный `tick`, `observe` двигает часы за remote, нет 64-битных сдвигов. |
| `packages/core_sync/lib/src/sync_event.dart` | все | Канонический protobuf фиксированного порядка, `id = SHA-256(domain || canonical)`, подпись над доменно-разделёнными байтами, `prevId`, лимит 512 KiB, `fromRecord` сверяет group/author/hlc/channel. |
| `packages/core_sync/lib/src/ingest_pipeline.dart` | все | Порядок размер → id → подпись → членство → prev → дедуп → запись; типизированные ошибки; `unknown` → pending, `notMember` → отказ. |
| `packages/core_sync/lib/src/projection.dart` | все | Membership по `(HLC, id)` строго до события; `never member` vs `removed`; tombstones применяются после создания сообщений, чужая правка игнорируется. |
| `packages/core_sync/lib/src/frame.dart` | все | Protobuf-кадры summary/range/window/events/gossip/ping, лимиты кадра и числа событий, курсор `(hlc, id)`. |
| `packages/core_sync/lib/src/sync_engine_impl.dart` | все | High/low lanes (окно канала раньше сводок), одна страница диапазона за раз, LRU id, `hops ≤ 4`, token bucket, `drain` для детерминированного симулятора. |
| `packages/core_sync/test/convergence_sim_test.dart` | все | 1000 seeded-прогонов, N=3, случайный порядок/потери/разделы; сравнение набора id и проекции. |
| `packages/core_sync/test/drift_e2e_test.dart` | все | `SyncEngineImpl` поверх `DriftEventStore`: сходимость/рестарт, channel-scoped `requestHistory`, восстановление pending после рестарта. |
| `packages/core_domain/lib/src/interfaces/sync_event_store.dart` | все | `eventsInRange(channelId)`, `pendingEvents`/`putPendingEvent`/`deletePendingEvent`; границы pending отдельно от append-only лога. |
| `packages/core_storage/lib/src/database/schema.dart` | миграция 7 | `pending_events`, индекс `(group_id, hlc, id)`, схема v7 без изменения append-only `events`. |
| `packages/core_protocol/lib/src/wire.dart` | varint/fixed | Арифметика вместо 32-битных `<<`/`|`; regression `test/wire_test.dart` для значений > 32 бит. |
| `apps/app/lib/di/providers.dart` | все | Riverpod: платформенный storage, `DriftEventStore`, Ed25519 identity/signer, `SyncEngineImpl`; fakes остались только для несвязанных слоёв. |
