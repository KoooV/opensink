# REVIEW_LIST.md — файлы и диапазоны для ручного ревью (слой 2)

Каждая запись: файл:диапазон, что проверять, критерий прохождения.

---

## 1. Подпись и деривация ключей из мнемоники

| Файл | Диапазон | Что проверять |
|------|----------|---------------|
| `packages/core_crypto/lib/src/bip39.dart` | 1–296 | Встроенный wordlist 2048 слов, SHA-256 на чистом Dart, PBKDF2-HMAC-SHA-512 (2048 итераций, соль `"mnemonic" + passphrase`), отказ от не-ASCII passphrase (`ArgumentError`), `mnemonicToEntropy` / `entropyToMnemonic` валидация checksum. |
| `packages/core_crypto/lib/src/identity.dart` | 1–173 | `recoverIdentityFromMnemonic()` использует `Ed25519().newKeyPairFromSeed(edMaterial)` и `X25519().newKeyPairFromSeed(xMaterial)` (публичные ключи из тех же seed, что и приватные — исправление D-03), `verifyBinding()` — подпись X25519 public key Ed25519 private key, `toString()` не раскрывает секреты. |
| `packages/core_crypto/lib/src/signer.dart` | 1–53 | `sign()` использует пару из однойパары (исправление D-02), `verify()` ловит все `Exception`/`Error` → `false` на некорректный ввод, нет временной ключевой пары с подменой public key. |

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
| `packages/core_crypto/test/x3dh_independent_test.dart` | все | Unabhängiger пересчёт SK, коммутативность DH, негативы (перестановка dh2||dh3, замена info, подмена SPK, подмена ed25519PublicKey). |

---

## 4. Double Ratchet

| Файл | Диапазон | Что проверять |
|------|----------|---------------|
| `packages/core_crypto/lib/src/e2ee/double_ratchet.dart` | 1–628 | `dhRatchetStep()` реализован (не UnimplementedError — исправление D-06), KDF_RK (HKDF-SHA-256, salt=prev rootKey, info=`"opensink/double-ratchet/root-key"`), KDF_CK один вызов HKDF outputLength 64 → split messageKey/nextChainKey (исправление D-18), `remoteDhPublicKey` из опционального поля при `hasOptionalDh` (исправление D-16), атомарность `skippedKeys` (исправление D-17), `_maxMessageNumber = 1 << 30` (исправление D-19), `maxSkip = 100` FIFO + TTL 24ч, header v1 формат, `toBytes`/`fromBytes` версии 1. |
| `packages/core_crypto/test/e2ee/double_ratchet_test.dart` | все | Ping-pong, out-of-order, потерянное сообщение, MAX_SKIP превышение, replay, порча шифртекста/заголовка, dhRatchetStep ключи меняются, сериализация v1, неизвестная версия → ошибка, toString秘密ность, атомарность (toBytes идентичен после неудачного decrypt), DoS на огромные messageNumber, forward secrecy (message key не в serialize), post-compromise. |

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
| `packages/platform_linux/lib/src/secure_key_store_linux.dart` | 1–214 | flutter_secure_storage → libsecret/secret-service, `checkDependencies()` probe-запись, `StoreUnavailable` при отсутствии Secret Service без отката на файл в открытом виде. |
| `packages/platform_web/lib/src/secure_key_store_web.dart` | 1–508 | `package:web` (v0.5.1) + `dart:js_interop`, **нет `dart:html`**, KEK: AES-GCM-256 `CryptoKey` `extractable: false` в IndexedDB, гонка вкладок в одной `readwrite` транзакции, AAD = имя ключа, `requestPersistentStorage()`, ошибки: `StoreUnavailable` / `StoreCorrupted` / `StoreError`. |
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