# Design doc: core_crypto

## 1. AEAD: XChaCha20-Poly1305

**Выбор:** `XChaCha20-Poly1305` (через `package:cryptography` `Xchacha20.poly1305Aead()`, v2.9.0, подтверждено spike-тестом).

**Формат зашифрованного блока (wire format):**
```
nonce(24 байта) || ciphertext || mac(16 байт)
```
Nonce генерируется случайным образом криптографически стойким генератором (`algorithm.newSecretKey()` не используется для nonce — nonce берется из `SecretBox.nonce` после `encrypt`). Nonce не передается извне в продакшене; для тестовых векторов в `XChaCha20Poly1305Aead.encrypt` зарезервирован именованный параметр `nonce` (`@visibleForTesting`).

**Обоснование выбора XChaCha20-Poly1305:**
- **Nonce misuse resistance.** В P2P-сети нет центрального координатора для отслеживания использованных nonce. XChaCha20-Poly1305 использует 192-битный nonce, который можно генерировать случайно без риска коллизии при день рождения-парадоксе (в отличие от 96-битного nonce AES-GCM).
- **Поддержка на Web:** Web Crypto API не поддерживает XChaCha20-Poly1305 нативно, но `package:cryptography` реализует его на чистом Dart, что работает одинаково на всех платформах.
- **Производительность на мобильных:** ChaCha20 быстрее AES на устройствах без AES-NI (многие Android-телефоны, эмуляторы).
- **Не изобретаем примитивы:** используем готовую реализацию из `package:cryptography`.

**Компромисс vs AES-GCM:**
| Критерий | XChaCha20-Poly1305 | AES-GCM |
|---|---|---|
| Nonce | 24 байта (случайный, безопасен) | 12 байт (требует учета использованных) |
| Повтор nonce | Повтор с тем же ключом недопустим, но риск коллизии при случайной генерации negligible | Повтор с тем же ключом → полное раскрытие ключа |
| Web Crypto API | Нет нативной поддержки (чистый Dart) | Есть нативная поддержка |
| Скорость (без AES-NI) | Быстрее | Медленнее |
| Скорость (с AES-NI) | Медленнее | Быстрее |

Выбран XChaCha20-Poly1305, так как в P2P-среде риск ошибки при ручном учете nonce AES-GCM выше, чем потеря производительности на платформах с AES-NI.

**Альтернатива (отклонена):** AES-GCM — требует строгого учета nonce (96 бит), уязвим к полному раскрытию ключа при повторе nonce, нативная поддержка на Web есть, но риск ошибки в P2P-среде слишком высок.

**AAD (Associated Data):** `encrypt`/`decrypt` принимают опциональный `aad`. Рекомендация для протокола (слой 3, Envelope): AAD = `groupId || senderPeerId || тип сообщения`. AAD не шифруется, но_authenticates_ — изменение AAD приводит к `DecryptionFailed`. Реализация проверки AAD остается на слое 3.

**Ошибки:** Неверный MAC, неверный ключ или tampered ciphertext → единый `DecryptionFailed` (причина не различается). Вход короче `nonceLength + macLength` (40 байт) → `DecryptionFailed` без попытки расшифровки.

**Тестовые векторы:**
- XChaCha20-Poly1305: пример #1 из `draft-arciszewski-xchacha-03` (подтверждено в тестах `package:cryptography` 2.9.0, `test/algorithms/xchacha20_test.dart`): key `8081...9f`, nonce `4041...57`, AAD `50515253c0c1c2c3c4c5c6c7`, plaintext "Ladies and Gentlemen of the class of '99: ...", ожидаемый MAC `c0875924c1c7987947deafd8780acf49`.
- HKDF (RFC 5869 Appendix A, SHA-256): Test Case 1, 2, 3.

## 2. SecureKeyStore: гарантии по платформам (фаза 3)

Контракт хранилища (см. §9): все методы возвращают `Result<T, KeyStoreError>`.
Отсутствие ключа (`IdentityNotFound`) и ошибки инфраструктуры (`StoreError`) — доменные ошибки, не исключения.

| Платформа | Реализация | Что защищено | Что НЕ защищено | Что делаем |
|-----------|-----------|--------------|-----------------|------------|
| Android | flutter_secure_storage → Keystore (v9.2.4) | Дамп файловой системы, доступ из других приложений; ключи изолированы Keystore/StrongBox (когда доступен) | Root-доступ comprometтирует хранилище; StrongBox не гарантирован на всех устройствах; Google Auto Backup может экспортировать ключи; ключи не восстанавливаются при переносе на новое устройство | Хранит IdentityBundle как зашифрованный blob через flutter_secure_storage. При ошибке хранилища — `StoreError` с понятным сообщением, без тихого отката на файл в открытом виде. |
| Linux | flutter_secure_storage → libsecret / secret-service (v9.2.4) | Доступ из-под других пользователей; данные зашифрованы паролем сеанса démonа | Root, тот же пользователь, нет TEE, зависит от наличия рабочего стола/ключ-ринг; Secret Service может быть недоступен | При отсутствии Secret Service — `StoreError` с инструкцией (установить/запустить libsecret, разблокировать keyring). Никакого тихого отката на файл в открытом виде. |
| Web | package:web + IndexedDB + Web Crypto API | Чтение дампа IndexedDB: KEK (AES-GCM, extractable: false) не извлекается в aberto | XSS крадёт ключи через JS-контекст; IndexedDB не зашифрован на диске браузера; нет аппаратной изоляции; персистентность зависит от `storage.persist()`; Ed25519 подписывается в Dart → неизвлекаемость самого identity-ключа недостижима | KEK хранится в IndexedDB как CryptoKey; оборачивает seed. Явно документировано: защита от дампа хранилища, не от XSS. |

**Общий вывод:** ни одна платформа не защищает от компрометации самого устройства. SecureKeyStore противодействует только утечке через файловую систему / другие приложения, а не от вредоносного ПО с правами пользователя.

## 3. E2EE

### Личные чаты: X3DH + Double Ratchet

В `package:cryptography` нет готового реализации Signal Protocol. Реализуем поверх примитивов:
- X25519 для ключевого обмена
- HKDF-SHA-256 для производной ключей
- XChaCha20-Poly1305 для AEAD

**X3DH:**'identité ключ (IK), эфемерный ключ (EK), предподписанный ключ (SPK), одноразовый ключ (OPK) — стандартный хендшейк Signal.
**Double Ratchet:** цепочка ключей цепочки (CK) и цепочка сообщений (MK) с Ratchet-шагом на каждое сообщение.

### Группы: Sender Keys

Каждый отправитель維 hält цепочку ключей (sender key chain) на группу. При изменении состава группы (уход/приход члена) выполняется ротация sender key (재generation + распространение через зашифрованный канал).

**Почему не библиотека:** нет аудитированной Dart-реализации Signal Protocol или libsignal. Реализуем сами поверх `package:cryptography` с опорой на спецификации Signal (X3DH, Double Ratchet, Sender Keys).

## 4. BIP-39

Зависимость: `bip39: ^3.0.0` (проверенная библиотека, стандартная в экосистеме Flutter/Dart).

## 5. Неизменяемые правила

- Нет собственных криптопримитивов.
- Сравнение подписей/MAC — constant-time (`package:cryptography` verify обеспечивает это на уровне алгоритма).
- Секреты не логируются (`toString` не раскрывает `SecretKey`).
- Доменные ошибки — `Result<T, E>` из `core_domain`.
- Все байты签署ются/шифруются ровно так, как идут по сети (protobuf не детерминирован — подписываем сериализованные байты, а не canonical JSON).

## 6. Verified API (package:cryptography 2.9.0, Dart 3.13.5)

Проверено spike-тестами в `packages/core_crypto/spike/api_spike_test.dart` (запуск: `dart test spike/`).
Источник: исходники `package:cryptography` 2.9.0 в pub-кэше, не по памяти.

| Что проверено | Как вызывается (код) | VM | Chrome | Вывод |
|---------------|----------------------|----|--------|-------|
| Ed25519 ключевая пара из seed | `Ed25519().newKeyPairFromSeed(seed)` → `extractPublicKey()` / `extractPrivateKeyBytes()` | ✅ | — | Публичный ключ парен приватному; вызов с тем же seed детерминистичен. |
| Ed25519 sign/verify | `Ed25519().sign(data, keyPair: kp)` → `Signature.bytes` (64); `verify(data, signature: sig)` | ✅ | — | Roundtrip проходит; чужие данные не проходят. |
| X25519 DH | `X25519().newKeyPairFromSeed(seed)` → `sharedSecretKey(keyPair:, remotePublicKey:)` → `extractBytes()` | ✅ | — | Два участника получают идентичный 32-байтный секрет. |
| XChaCha20-Poly1305 | `Xchacha20.poly1305Aead()`; `nonceLength` 24, `secretKeyLength` 32, `SecretBox.mac.bytes` 16 | ✅ | — | Неверный MAC → `SecretBoxAuthenticationError` (не иное исключение). |
| HKDF (RFC 5869) | `Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(secretKey:, nonce:, info:)` | ✅ | — | Параметры `hmac`/`outputLength`/`nonce`/`info` принимаются; выход 32 байта. |
| PBKDF2 | `Pbkdf2(macAlgorithm: Hmac.sha512(), iterations: 2048, bits: 512).deriveKey(secretKey:, nonce:)` | ✅ | — | Выход 512 бит (64 байта). |

Chrome в данном окружении отсутствует — проверка только на VM (см. docs/OPEN_QUESTIONS.md Q4).

## 7. TODO(verify) (перенесено в docs/OPEN_QUESTIONS.md)

- Совместимость `bip39` с Dart 3.13.5.
- Web Crypto API: `deriveKey` с PBKDF2-HMAC-SHA512 для BIP-39 seed на вебе.
- flutter_secure_storage версия с поддержкой Linux.
- Механизм подключения platform-реализации SecureKeyStore через DI (docs/OPEN_QUESTIONS.md Q2).

## 8. Identity и мнемоника (слой 2, фаза 1)

### 8.1 Выбор:mnemonic и seed

BIP-39 мнемонима 12 слов (128 бит энтропии). Обоснование:
- 12 слов достаточно для 128 бит безопасности, что соответствует уровню Ed25519/X25519.
- 24 слова (256 бит) избыточны для нашей угрозы модели и увеличивают нагрузку на пользователя.
- Встроенный английский wordlist (2048 слов) — без внешней зависимости `package:bip39`. Сравнение: пакет `bip39` добавляет внешнюю зависимость, её лицензию и支持ность нужно отслеживать; собственная реализация ограничивается кодированием (wordlist + checksum), что не запрещено правилами (примитивы — только из `package:cryptography`).

Seed: PBKDF2-HMAC-SHA-512, 2048 итераций, соль `"mnemonic" + passphrase`, длина 512 бит (64 байта). Реализовано в `Bip39.mnemonicToSeed()` (core_crypto/lib/src/bip39.dart).

### 8.2 Производство ключей из seed

HKDF-SHA-256 с разными versioned info для Ed25519 и X25519:
- `opensink/identity/ed25519/v1` → 32 байта → `Ed25519().newKeyPairFromSeed(seed)` → пара ключей
- `opensink/identity/x25519/v1` → 32 байта → `X25519().newKeyPairFromSeed(seed)` → пара ключей

Ключи независимы: разные info, разные пары. Публичные ключи производятся из тех же seed, что и приватные (исправляет D-03).

### 8.3 Binding X25519 → Ed25519

Открытый ключ X25519 подписывается закрытым ключом Ed25519. Подпись хранится в `CryptoIdentity.x25519BindingSignature` (hex). Метод `verifyBinding()` проверяет подпись. Подмена X25519 ключа без переподписи делает binding неверным.

### 8.4 Domain separation

Контекст подписи (domain separation) не реализуется на этом слое — задача слоя 3 (Envelope). `CryptoSigner.sign()` подписывает сырые байты как есть.

### 8.5 Секреты в toString()

`toString()` у `CryptoIdentity` и любых объектов с секретами не раскрывает содержимое `SecretKey`, `peerId` или `mnemonic`. Проверяется тестом.

### 8.6 Измерение PBKDF2

PBKDF2-HMAC-SHA-512 (2048 итераций, 512 бит) на VM: ~33.6 ms на одну derived-ключ (10 итераций в среднем, Dart VM, без JIT-прогрева после первого вызова). Измерено скриптом `tool/pbkdf2_bench.dart`. Chrome-замер отложен (см. docs/OPEN_QUESTIONS.md Q4).

---

## 9. SecureKeyStore: интерфейс и контракт (фаза 3)

Интерфейс объявлен в `core_domain` (`lib/src/interfaces/secure_key_store.dart`) и используется `core_crypto` + `platform_*`.

Все методы возвращают `Result<T, KeyStoreError>`:
- `storeIdentity(UserId, IdentityBundle)` → `Result<void, KeyStoreError>`
- `loadIdentity(UserId)` → `Result<IdentityBundle, KeyStoreError>` (`Err(IdentityNotFound)` при отсутствии ключа, `Err(StoreError)` при сбое инфраструктуры)
- `deleteIdentity(UserId)` → `Result<void, KeyStoreError>`
- `hasIdentity(UserId)` → `Result<bool, KeyStoreError>`

`KeyStoreError` (сеaled, в core_domain):
- `IdentityNotFound` — ключ отсутствует (не является аварийной ситуацией).
- `StoreError(String message)` — сбой инфраструктурного хранилища. В сообщении не раскрываются секреты.

Инфраструктурные исключения (например, от `flutter_secure_storage` или IndexedDB) ловятся и оборачиваются в `StoreError`; они не пробрасываются наружу.

### 10. MemorySecureKeyStore (core_crypto)

- `@visibleForTesting`, комментарий: «не для продакшена».
- Хранит `IdentityBundle` в памяти (verbatim, без самодостаточного шифрования).
- `loadIdentity` при отсутствии ключа → `Err(IdentityNotFound)`.
- `toString()` не раскрывает содержимое `encryptedPrivateKey` (проверяется тестом).

### 11. Содержимое IdentityBundle (раздел Б)

Поле `encryptedPrivateKey` содержит приватный ключ (seed) пользователя.
Оно **не является самодостаточным шифртекстом**: в `core_crypto` нет мастер-ключа (D-04 закрыта как by design), поэтому `MemorySecureKeyStore` хранит поле verbatim. Защита обеспечивается **платформенным хранилищем** (flutter_secure_storage → Keystore/libsecret), которое шифрует данные при записи.

Решение (обосновано): **(А) основное** — seed хранится как blob в защищённом хранилище платформы. Выбрано, потому что:
- не требует ввода пароля пользователя при каждом запуске (лучший UX);
- шифрование при.rest delegated на зрелую платформенную реализацию (Keystore/libsecret);
- в `core_crypto` нет мастер-ключа, а вводить его избыточно для базового сценария.

**(Б) отложена** — дополнительно KEK из passphrase для экспорта и резервной копии:
- KDF: PBKDF2-HMAC-SHA-512 (уже проверено в фазе 0, `package:cryptography` 2.9.0, `Pbkdf2(macAlgorithm: Hmac.sha512(), iterations: 2048, bits: 512)`).
- На Web PBKDF2 через Web Crypto API `SubtleCrypto.deriveKey` с `Pbkdf2Params` (поддержка в `package:web` — TODO(verify): проверить работу `Pbkdf2` из `package:cryptography` на вебе и надёжность `storage.persist()`).
- Используется только для экспорта/резервной копии, не для основного разблокирования.

Переименование `encryptedPrivateKey` → `privateSeed` не выполнено: поле действительно защищено шифрованием,只不过 на уровне платформы, а не внутри `core_crypto`. В DESIGN.md задокументировано, что защита обеспечивается хранилищем платформы.

### 12. Web-реализация (platform_web, фаза 3)

Переписана на `package:web` (v0.5.1) + `dart:js_interop`; `dart:html` удалён.

Дизайн:
- При инициализации открывается IndexedDB (база `opensink_keystore`, хранилища `keys` и `identities`).
- KEK — AES-GCM-256 `CryptoKey` с `extractable: false`,usage `wrapKey | unwrapKey`, генерируется один раз и хранится в IndexedDB как объект `CryptoKey` (структурное клонирование; сырой ключ не出现在 дампе в aberto).
- При `storeIdentity`: `IdentityBundle` сериализуется в JSON, шифруется AES-GCM (случайный IV) с помощью KEK, пара `{iv, ciphertext}` сохраняется в `identities`.
- При `loadIdentity`: читается `{iv, ciphertext}`, расшифровывается KEK, десериализуется.
- При `deleteIdentity`: запись удаляется из `identities`.
- При `hasIdentity`: проверка наличия записи.

Честная оценка ограничений (см. таблицу угроз §2):
- Защищает от чтения дампа IndexedDB (KEK не извлекается).
- Не защищает от XSS: злоумышленник с выполнением JS может использовать KEK через Web Crypto API.
- Неизвлекаемость самого identity-ключа (Ed25519/X25519 приватных ключей) на web недостижима, так как подпись выполняется в Dart (package:cryptography) над расшифрованным в памяти ключом.
- Персистентность не гарантирована без `storage.persist()`.

TODO(verify):
- Точные сигнатуры `SubtleCrypto.generateKey`/`encrypt`/`decrypt` и конвертация `JSPromise`→`Future`, `JSArrayBuffer`→`Uint8List` в `package:web` 0.5.1 (по факту сверены с исходниками пакета).
- Работа `package:cryptography` Pbkdf2 на вебе (для опции Б).
- Работа IndexedDB + `storage.persist()` в тестовом Chrome.

