# Design doc: проект opensink (общий)

Восстановлен по коду и тестам на момент фазы F6. Каждое утверждение сверено с `packages/core_*/lib/`, `packages/core_*/test/` и `docs/DEFECTS.md`.

## 0. Стек и версии (по pubspec.lock / pubspec.yaml)

| Компонент | Версия | Источник |
|-----------|--------|----------|
| Dart SDK | 3.13.5 | `pubspec.yaml:22` |
| `package:cryptography` | 2.9.0 | `pubspec.lock:163` |
| `flutter_secure_storage` | 9.2.4 | `docs/DEFECTS.md:30` |
| Melos workspace | 17 пакетов | `pubspec.yaml:62-76` |

## 1. Архитектура пакетов (по коду)

Все `core_*` пакеты — чистый Dart, без `dart:io`, `dart:html`, `package:web`, `dart:js_interop` (подтверждено `tool/check_core_imports.sh`). Платформенный код только в `platform_*`.

| Пакет | Назначение | Код |
|-------|-----------|-----|
| `core_domain` | Модели, интерфейсы, `Result<T,E>`, fakes | `packages/core_domain/lib/` |
| `core_crypto` | Identity, Ed25519, X25519, HKDF, PBKDF2, XChaCha20-Poly1305, BIP-39, X3DH, Double Ratchet, Sender Keys, StateVault, SecureKeyStore | `packages/core_crypto/lib/src/` |
| `core_protocol` | Protobuf wire/envelope, сообщения и лимиты | `packages/core_protocol/lib/` |
| `core_storage` | Drift схема, EventStore, `SyncEventStore` (Q18) | `packages/core_storage/lib/` |
| `core_signaling` | Nostr и WebSocket-трекеры; LAN/QR и открытые задачи — Q17/Q35 | `packages/core_signaling/lib/` |
| `core_peer` | Прямые WebRTC-соединения: `WebRtcPeerLink`, `WebRtcTransport`, Flutter-адаптер (Q14) | `packages/core_peer/lib/`, `packages/core_peer/DESIGN.md` |
| `core_sync` | HLC-лог, anti-entropy, gossip, приоритетная загрузка, tombstones (Q19) | `packages/core_sync/lib/`, `packages/core_sync/DESIGN.md` |
| `core_group` | GroupState, права, валидация подписей — заглушка (Q12) | `packages/core_group/lib/core_group.dart:3` |
| `core_relay` | Маршрутизация через участников — заглушка (Q16) | `packages/core_relay/lib/core_relay.dart:3` |
| `core_media` | Звонки, экран, топологии — заглушка (Q13) | `packages/core_media/lib/core_media.dart:3` |
| `platform_android` | SecureKeyStore на flutter_secure_storage / Keystore | `packages/platform_android/lib/` |
| `platform_linux` | SecureKeyStore на flutter_secure_storage / libsecret | `packages/platform_linux/lib/` |
| `platform_web` | SecureKeyStore на package:web + IndexedDB + Web Crypto | `packages/platform_web/lib/` |
| `apps/app` | DI провайдеры, UI | `apps/app/lib/` |

## 2. Криптография (по коду core_crypto)

### 2.1 Примитивы (package:cryptography 2.9.0, spike-подтверждено)

Все примитивы из `package:cryptography`, никаких собственных криптопримитивов (DESIGN.md §5.1 core_crypto):

- **Ed25519** — `Ed25519().newKeyPairFromSeed(seed)`, `sign()`, `verify()` (64-байтная подпись). Проверено: roundtrip, чужие данные не проходят, детерминизм по seed.
- **X25519** — `X25519().newKeyPairFromSeed(seed)`, `sharedSecretKey()`. Проверено: оба участника получают идентичный 32-байтный секрет (RFC 7748 §6.1 вектор).
- **XChaCha20-Poly1305** — `Xchacha20.poly1305Aead()`, nonce 24 байта, ключ 32 байта, MAC 16 байт. Неверный MAC → `SecretBoxAuthenticationError`.
- **HKDF (RFC 5869)** — `Hkdf(hmac: Hmac.sha256(), outputLength: 32)`. Проверено: выход 32 байта, тестовые векторы RFC 5869 App. A.
- **PBKDF2** — `Pbkdf2(macAlgorithm: Hmac.sha512(), iterations: 2048, bits: 512)`. Проверено: выход 512 бит (64 байта). Замер на VM: ~33.6 ms (холодный старт) / ~181 ms (первый вызов).

### 2.2 BIP-39 (встроенная реализация, НЕ 외부 зависимость)

В `packages/core_crypto/lib/src/bip39.dart` и `bip39_wordlist.dart`. Внешний пакет `bip39` НЕ используется (DESIGN.md §4.1 core_crypto, §8.1 core_crypto):
- Английский wordlist 2048 слов, встроен в репозиторий.
- SHA-256 реализована на чистом Dart (`Bip39._sha256`), т.к. в `package:cryptography` v2.9.0 нет синхронного hash API.
- Seed: PBKDF2-HMAC-SHA-512, 2048 итераций, соль `"mnemonic" + passphrase`, 512 бит.

### 2.3 NFKD / парольная фраза (решение F3)

Dart std lib не имеет Unicode нормализации (NFC/NFD/NFKD). Решение (фиксировано в `packages/core_crypto/DESIGN.md §4.2`):
- Не-ASCII парольная фраза в `Bip39.mnemonicToSeed()` → `ArgumentError('Non-ASCII passphrase is not supported')`.
- ASCII парольные фразы принимаются без ограничений (включая «TREZOR»).
- Обоснование: без внешней зависимости `unorm_dart`, однозначное поведение на всех платформах, предотвращение расхождения NFC/NFD seed.

### 2.4 AEAD (XChaCha20-Poly1305)

Wire format: `nonce(24) || ciphertext || mac(16)` (`packages/core_crypto/lib/src/aead.dart`). Nonce генерируется случайно. AAD опционален. Ошибки — единый `DecryptionFailed` без раскрытия причины.

## 3. E2EE (слой 2)

### 3.1 X3DH (ослабленный вариант без OPK)

`packages/core_crypto/lib/src/e2ee/x3dh.dart`:
- IK + SPK, OPK удалён (нет координатора для гарантии одноразовости в P2P).
- SPK привязка: X25519 SPK public key подписывается Ed25519 private key IK. Контекст: `"opensink/x3dh/spk-binding/v1|" + spkBytes`.
- `sender()` возвращает `CryptoResult<X3DHSenderResult>`, ошибка привязки → `Err(InvalidSignature)` без исключения.
- `receiver()` работает с локальным бандлом (привязка действительна по конструкции).

### 3.2 Double Ratchet

`packages/core_crypto/lib/src/e2ee/double_ratchet.dart` (628 строк):
- `dhRatchetStep()` — **реализован** (не заглушка, дефект D-06 исправлен в фазе F2): X25519.sharedSecretKey + KDF_RK (HKDF-SHA-256, salt=предыдущий rootKey, info=`"opensink/double-ratchet/root-key"`), генерация новой DH-пары, пропущенные ключи MAX_SKIP=100, TTL=24ч.
- KDF_CK: один вызов HKDF с outputLength 64, split на messageKey (32) + nextChainKey (32) (дефект D-18 исправлен).
- Header v1: `version(1) || flags(1) || ephemeralPK(32) || messageNumber(8 LE) || prevChainLength(8 LE) || [dhPublicKey(32) optional] || nonce(24) || ciphertext || mac(16)`.
- AAD = header bytes || associated data.
- `toBytes()`/`fromBytes()` версии 1 с проверкой версии.
- Replay protection: `messageNumber < receivingMessageCounter` и не в `skippedKeys` → отказ.
- Атомарность: `skippedKeys` не мутирует до успешной AEAD (дефект D-17 исправлен).
- DoS-защита: `_maxMessageNumber = 1 << 30`, `maxSkip = 100` с FIFO-вытеснением.

### 3.3 Sender Keys (группы)

`packages/core_crypto/lib/src/e2ee/sender_keys.dart` (312 строк):
- `SenderKey`: chainKey + Ed25519 signingKeyPair + sequenceNumber + groupId + senderPeerId.
- Encrypt: KDF_CK + AEAD + подпись Ed25519 (ciphertext || header).
- Decrypt: проверка подписи первой, затем расшифровка.
- Replay protection: окно 100 sequence numbers, независимо по senderPeerId.
- Ротация: новая цепочка + новая пара подписи, раздача через личные E2E-каналы.

### 3.4 StateVault (защита состояний при хранении, фаза F5)

`packages/core_crypto/lib/src/state_vault.dart` (279 строк):
- `seal(Uint8List, StateVaultContext) -> Future<VaultResult<SealedState>>`
- `open(SealedState, StateVaultContext) -> Future<VaultResult<Uint8List>>`
- Ключ хранилища: случайный 256-битный, хранится в `SecureKeyStore` под `opensink_state_vault_v1`, не выводится из identity seed.
- Конверт v1: `version(1) || kind(1) || stateIdLen(2 LE) || stateId || nonce(24) || ciphertext || mac(16)`.
- AAD: `utf8("opensink/state/v1") || kind(1) || stateIdLen(2 LE) || stateId || context.formatVersion(1)`.
- AEAD: XChaCha20-Poly1305.
- `open()` проверяет заголовок конвента перед расшифровкой.
- Все ошибки через `VaultResult<T>` (sealed classes), нет исключений.

### 3.5 SecureKeyStore (contrat)

Объявлен в `core_domain` (`lib/src/interfaces/secure_key_store.dart`), все методы возвращают `Result<T, KeyStoreError>`:
- `storeIdentity`, `loadIdentity`, `deleteIdentity`, `hasIdentity`, `storeKey`, `loadKey`, `deleteKey`.
- `KeyStoreError`: `IdentityNotFound`, `StoreError`, `StoreUnavailable`, `StoreCorrupted`, `StoreAccessDenied`.
- Реализации: `MemorySecureKeyStore` (core_crypto, verbatim, @visibleForTesting), `platform_android` (flutter_secure_storage → Keystore), `platform_linux` (flutter_secure_storage → libsecret), `platform_web` (package:web + IndexedDB + Web Crypto).

## 4. Модель угроз по платформам (F4A / F4B)

| Платформа | Что защищено | Что НЕ защищено |
|-----------|-------------|-----------------|
| Android | Дамп ФС, доступ из других приложений, Keystore изоляция | Root, StrongBox не гарантирован, Google Auto Backup, нет восстановления на новом устройстве |
| Linux | Доступ других пользователей, пароль сеанса ключ-ринг | Root, тот же пользователь, нет TEE, зависит от рабочего стола |
| Web | Дамп IndexedDB (KEK — `CryptoKey` extractable: false), подмена blob (AAD = имя ключа) | XSS, нет аппаратной изоляции, персистентность зависит от `storage.persist()`, seed в памяти не затирается |

Ни одна платформа не защищает от компрометации самого устройства (уровень пользователя).

## 5. Отклонения от Signal

Реализация не является Signal-совместимой (core_crypto DESIGN.md §13.6):

1. **Нет One-Time Prekeys (OPK)** — отказ в фазе F4A, нет координатора в P2P.
2. **IK не регистрируется на сервере** — bundle передаётся напрямую (приглашение / групповой лог).
3. **AAD и заголовок Double Ratchet** — собственный формат, не Noise Protocol framed как в Signal.
4. **MAX_SKIP / TTL skipped keys** — собственные значения (100 / 24 ч), не подтверждены источником Signal.
5. **Ротация Sender Keys** по триггеру слоя 8, а не фиксированный интервал.
6. **Сериализация состояния** — собственный формат версии 1, не protobuf Signal.

## 6. Verified API (package:cryptography 2.9.0)

Подтверждено spike-тестами в `packages/core_crypto/spike/api_spike_test.dart`:

| Что проверено | Код | VM | Chrome | Вывод |
|---------------|-----|----|--------|-------|
| Ed25519 ключевая пара из seed | `Ed25519().newKeyPairFromSeed(seed)` → `extractPublicKey()` / `extractPrivateKeyBytes()` | ✅ | — | Публичный ключ парен приватному; детерминистичен. |
| Ed25519 sign/verify | `Ed25519().sign(data, keyPair: kp)` → 64 байт; `verify()` | ✅ | — | Roundtrip проходит; чужие данные не проходят. |
| X25519 DH | `X25519().newKeyPairFromSeed(seed)` → `sharedSecretKey()` → 32 байта | ✅ | — | Одинаковый секрет у обоих участников. |
| XChaCha20-Poly1305 | `Xchacha20.poly1305Aead()`; nonce 24, ключ 32, MAC 16 | ✅ | — | Неверный MAC → `SecretBoxAuthenticationError`. |
| HKDF (RFC 5869) | `Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(...)` | ✅ | — | Выход 32 байта. |
| PBKDF2 | `Pbkdf2(macAlgorithm: Hmac.sha512(), iterations: 2048, bits: 512).deriveKey(...)` | ✅ | — | Выход 512 бит (64 байта). |

Chrome в текущем окружении отсутствует — проверка только на VM (см. Q4 OPEN_QUESTIONS.md).

## 7. Замеры производительности (VM, фаза F1)

| Операция | Время | Источник |
|----------|-------|----------|
| PBKDF2-HMAC-SHA-512 (2048 iters, 512 бит) | ~33.6 ms (холодный), ~181 ms (первый вызов) | `tool/pbkdf2_bench.dart`, PHASE_LOG запись 2 |
| AEAD encrypt 1 МБ | < 1 ms | PHASE_LOG запись 7 |
| 1000 × AEAD encrypt малого текста | < 1 ms | PHASE_LOG запись 7 |
| Полный прогон 196 тестов (core_crypto) | ~4 сек | PHASE_LOG запись 12 |

Chrome-замеры отложены (Q4: рантайм `package:test` не отдаёт `dart.js` с MIME-типом `application/javascript`).

## 8. Хранение состояний (фаза F5)

StateVault запечатывает сериализованные состояния Double Ratchet и Sender Key перед записью в хранилище (drift: SQLite / OPFS). Ключ хранилища — независимый случайный 256-битный ключ в `SecureKeyStore`, не выводится из identity seed. Потеря ключа → сессии E2EE устанавливаются заново (принятый остаточный риск). Защита от rollback (подмена состояния старой версией) не реализована — требует защищённого монотонного счётчика (D-21 в DEFECTS.md).

## 9. Контракты для соседних слоёв

### 9.1 Слой 3 (Envelope / транспорт)

- **Подпись и AAD считаются над байтами, переданными по сети, без повторной сериализации перед verify.** Protobuf не детерминирован — подписываются и шифруются сериализованные байты, а не canonical JSON (core_crypto DESIGN.md §5.5).
- **Домен-разделение (domain separation):** префикс-метка на каждый тип сообщения:
  ```
  opensink/<layer>/<message-type>/v1|
  ```
  Примеры: `opensink/3/envelope/v1|`, `opensink/5/double-ratchet/v1|`, `opensink/5/sender-key/v1|`, `opensink/8/group-event/v1|`.
  Префикс конкатенируется с сырыми байтами сообщения перед подписью / AAD. Формат предложен, требует утверждения слоем 3 (TODO(verify): точные сигнатуры, кодирование).

### 9.2 Слой 8 (членство, логи, ротация)

- **Триггеры ротации sender keys:** изменение состава группы (уход / приход члена), истечение TTL SPK (например, 7 дней), ручная инициация пользователем. Решение о ротации — слой 8.
- **Раздача:** новый sender key шифруется под сессию Double Ratchet каждого члена группы (`X3DH.sender()` + AEAD) и отправляется как `SenderKeyDistributionMessage` по личному E2E-каналу (core_crypto DESIGN.md §13.4).

### 9.3 Слои 5 и 7 (replay сигналинга и событий)

- **Не в core_crypto.** core_crypto обеспечивает криптографическую целостность и аутентичность, но не отслеживает использованные nonce / sequence на уровне AEAD (AEAD stateless — тот же шифртекст расшифровывается многократно).
- **Слой 5:** Double Ratchet — replay protection на уровне `messageNumber`; Sender Keys — `acceptSequence` с окном 100.
- **Слой 7:** дедупликация по идентификатору события в групповом логе.
- **Слой 8:** TTL, grace period, триггеры ротации SPK / sender key.

## 10. Ссылки

- `packages/core_crypto/DESIGN.md` — полный design doc core_crypto (AEAD, SecureKeyStore, E2EE, BIP-39, Identity, replay, StateVault).
- `docs/DEFECTS.md` — реестр дефектов (D-01…D-23).
- `docs/OPEN_QUESTIONS.md` — открытые вопросы (Q1…Q24).
- `docs/PHASE_LOG.md` — журнал фаз разработки.
- `docs/LAYER2_ACCEPTANCE.md` — критерии приёмки слоя 2 с доказательствами.
- `docs/LAYER7_ACCEPTANCE.md` — критерии приёмки core_sync с доказательствами.
- `docs/REVIEW_LIST.md` — файлы и диапазоны для ручного ревью.