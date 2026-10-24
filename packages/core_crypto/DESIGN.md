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
| Android | flutter_secure_storage → Keystore (v9.2.4) | Дамп файловой системы, доступ из других приложений; ключи изолированы Keystore/StrongBox (когда доступен) | Root-доступ компрометирует хранилище; StrongBox не гарантирован на всех устройствах; Google Auto Backup может экспортировать ключи; ключи не восстанавливаются при переносе на новое устройство | Хранит IdentityBundle как зашифрованный blob через flutter_secure_storage. При ошибке хранилища — `StoreError`/`StoreUnavailable`/`StoreCorrupted` с понятным сообщением, без тихого отката на файл в открытом виде. |
| Linux | flutter_secure_storage → libsecret / secret-service (v9.2.4) | Доступ из-под других пользователей; данные зашифрованы паролем сеанса демон | Root, тот же пользователь, нет TEE, зависит от наличия рабочего стола/ключ-ринг; Secret Service может быть недоступен | При отсутствии Secret Service — `StoreError` с инструкцией (установить/запустить libsecret, разблокировать keyring). Никакого тихого отката на файл в открытом виде. |
| Web | package:web + IndexedDB + Web Crypto API | Чтение дампа IndexedDB: KEK (AES-GCM, extractable: false) не извлекается в aberto | XSS крадёт ключи через JS-контекст; IndexedDB не зашифрован на диске браузера; нет аппаратной изоляции; персистентность зависит от `storage.persist()`; Ed25519 подписывается в Dart → неизвлекаемость самого identity-ключа недостижима | KEK хранится в IndexedDB как CryptoKey; оборачивает seed. Явно документировано: защита от дампа хранилища, не от XSS. |

**Общий вывод:** ни одна платформа не защищает от компрометации самого устройства. SecureKeyStore противодействует только утечке через файловую систему / другие приложения, а не от вредоносного ПО с правами пользователя.

## 3. E2EE

### Личные чаты: X3DH + Double Ratchet

В `package:cryptography` нет готового реализации Signal Protocol. Реализуем поверх примитивов:
- X25519 для ключевого обмена
- HKDF-SHA-256 для производной ключей
- XChaCha20-Poly1305 для AEAD

**X3DH:** IK ключ (identity key), эфемерный ключ (EK), предподписанный ключ (SPK), одноразовый ключ (OPK) — стандартный хендшейк Signal.
**Double Ratchet:** цепочка ключей цепочки (CK) и цепочка сообщений (MK) с Ratchet-шагом на каждое сообщение.

### Группы: Sender Keys

Каждый отправитель хранит цепочку ключей (sender key chain) на группу. При изменении состава группы (уход/приход члена) выполняется ротация sender key (regeneration + распространение через зашифрованный канал).

**Почему не библиотека:** нет аудитированной Dart-реализации Signal Protocol или libsignal. Реализуем сами поверх `package:cryptography` с опорой на спецификации Signal (X3DH, Double Ratchet, Sender Keys).

## 4. BIP-39

### 4.1 Реализация

Встроенный английский wordlist (2048 слов) — без внешней зависимости `package:bip39`.
Собственная реализация ограничивается кодированием (wordlist + checksum), что не запрещено правилами (примитивы — только из `package:cryptography`).

SHA-256 реализована на чистом Dart в `Bip39._sha256` (в `package:cryptography` v2.9.0 нет синхронного hash API).

### 4.2 NFKD / парольная фраза (passphrase)

**Проблема:** BIP-39 требует нормализации парольной фразы через NFKD перед PBKDF2. Dart стандартная библиотека не предоставляет Unicode нормализации (ни NFC, ни NFD, ни NFKD).

**Рассмотренные варианты:**
- **А) Пакет `unorm_dart`:** чистый Dart, лицензия MIT, поддерживает Web. Требует добавления внешней зависимости, проверки лицензии и поддержки на всех целевых платформах (Linux, Android, Web).
- **Б) Явный отказ от не-ASCII парольной фразы:** не-ASCII символы в `passphrase` приводят к `ArgumentError` в `Bip39.mnemonicToSeed()`.

**Решение:** вариант **Б** (явный отказ). Обоснование:
- не требует внешних зависимостей;
- однозначное поведение: одинаковая строка на всех платформах даёт одинаковый seed;
- не-ASCII парольные фразы — крайний случай; пользователь может использовать ASCII-пароль;
- NFC и NFD формы не-ASCII символа дают разные seed без нормализации, что является источником ошибок — отказ предотвращает это.

**Поведение:**
- `Bip39.mnemonicToSeed(mnemonic, passphrase: 'non-ascii')` → `ArgumentError('Non-ASCII passphrase is not supported')`.
- ASCII парольные фразы (включая 'TREZOR') принимаются без ограничений.
- Проверено тестом: `bip39_integrity_test.dart`, группа "BIP-39: NFKD / пассфраза".

## 5. Неизменяемые правила

- Нет собственных криптопримитивов.
- Сравнение подписей/MAC — constant-time (`package:cryptography` verify обеспечивает это на уровне алгоритма).
- Секреты не логируются (`toString` не раскрывает `SecretKey`).
- Доменные ошибки — `Result<T, E>` из `core_domain`.
- Все байты подписываются/шифруются ровно так, как идут по сети (protobuf не детерминирован — подписываем сериализованные байты, а не canonical JSON).

### Ограничение Dart: безопасное затирание памяти

Dart не гарантирует безопасное затирание секретных байт в памяти:
- `Uint8List`/`List<int>` могут быть перемещены GC, старые копии сохраняются в куче.
- Нет стандартного API для `memset`-подобного обнуления с гарантией, что компилятор не оптимизирует запись.
- `SecretKey` из `package:cryptography` хранит байт в Dart-объекте; при удалении ссылки байты могут остаться в памяти до следующего GC-цикла.

**Последствие:** core_crypto не может гарантировать стирание ключей из памяти после использования. Защита компилируется на уровне платформы (SecureKeyStore, Keystore/libsecret) и на уровне приложения (минимизация времени жизни ключа в памяти, пересоздание изолятов). Это документировано как известное ограничение платформы Dart.

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

Chrome — проверка пройдена; набор тестов совпадает с VM.

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
- Встроенный английский wordlist (2048 слов) — без внешней зависимости `package:bip39`. Сравнение: пакет `bip39` добавляет внешнюю зависимость, её лицензию и поддержку нужно отслеживать; собственная реализация ограничивается кодированием (wordlist + checksum), что не запрещено правилами (примитивы — только из `package:cryptography`).

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

PBKDF2-HMAC-SHA-512 (2048 итераций, 512 бит) на VM: ~33.6 ms на одну derived-ключ (10 итераций в среднем, Dart VM, без JIT-прогрева после первого вызова). Измерено скриптом `tool/pbkdf2_bench.dart`. Отдельный Chrome-замер не проводился.

---

## 9. SecureKeyStore: интерфейс и контракт (фаза 3)

Интерфейс объявлен в `core_domain` (`lib/src/interfaces/secure_key_store.dart`) и используется `core_crypto` + `platform_*`.

Все методы возвращают `Result<T, KeyStoreError>`:
- `storeIdentity(UserId, IdentityBundle)` → `Result<void, KeyStoreError>`
- `loadIdentity(UserId)` → `Result<IdentityBundle, KeyStoreError>` (`Err(IdentityNotFound)` при отсутствии ключа, `Err(StoreError)` при сбое инфраструктуры)
- `deleteIdentity(UserId)` → `Result<void, KeyStoreError>`
- `hasIdentity(UserId)` → `Result<bool, KeyStoreError>`

`KeyStoreError` (sealed, в core_domain):
- `IdentityNotFound` — ключ отсутствует (не является аварийной ситуацией).
- `StoreError(String message)` — сбой инфраструктурного хранилища. В сообщении не раскрываются секреты.

Инфраструктурные исключения (например, от `flutter_secure_storage` или IndexedDB) ловятся и оборачиваются в `StoreError`; они не пробрасываются наружу.

### 10. MemorySecureKeyStore (core_crypto)

- `@visibleForTesting`, комментарий: «не для продакшена».
- Хранит `IdentityBundle` в памяти (verbatim, без самодостаточного шифрования).
- `loadIdentity` при отсутствии ключа → `Err(IdentityNotFound)`.
- `toString()` не раскрывает содержимое `privateSeed` (проверяется тестом).

### 11. Содержимое IdentityBundle (раздел Б)

Поле `privateSeed` содержит приватный ключ (seed) пользователя.
Оно **не является самодостаточным шифртекстом**: в `core_crypto` нет мастер-ключа (D-04 закрыта как by design), поэтому `MemorySecureKeyStore` хранит поле verbatim. Защита обеспечивается **платформенным хранилищем** (flutter_secure_storage → Keystore/libsecret), которое шифрует данные при записи.

Решение (обосновано): **(А) основное** — seed хранится как blob в защищённом хранилище платформы. Выбрано, потому что:
- не требует ввода пароля пользователя при каждом запуске (лучший UX);
- шифрование при.rest delegated на зрелую платформенную реализацию (Keystore/libsecret);
- в `core_crypto` нет мастер-ключа, а вводить его избыточно для базового сценария.

**(Б) отложена** — дополнительно KEK из passphrase для экспорта и резервной копии:
- KDF: PBKDF2-HMAC-SHA-512 (уже проверено в фазе 0, `package:cryptography` 2.9.0, `Pbkdf2(macAlgorithm: Hmac.sha512(), iterations: 2048, bits: 512)`).
- На Web PBKDF2 через Web Crypto API `SubtleCrypto.deriveKey` с `Pbkdf2Params` (поддержка в `package:web` — TODO(verify): проверить работу `Pbkdf2` из `package:cryptography` на вебе и надёжность `storage.persist()`).
- Используется только для экспорта/резервной копии, не для основного разблокирования.

Переименование `encryptedPrivateKey` → `privateSeed` выполнено (фаза F4A): поле не подразумевает шифрования на уровне приложения, защита обеспечивается хранилищем платформы.

### 11.1. Формат записи в платформенном хранилище

Ключ: `opensink_identity_v1:<userId>` (префикс + версия схемы).
Значение: JSON с полями `userId`, `publicKey`, `privateSeed` (base64), `createdAt`, `schemaVersion: 1`.
При несовместимой версии схемы → `StoreCorrupted`. При повреждённых данных → `StoreCorrupted`.


### 12. Web-реализация (platform_web, фаза 3/4B)

Переписана на `package:web` (v0.5.1) + `dart:js_interop`; `dart:html` не используется.

#### 12.1 Дизайн

- При инициализации открывается IndexedDB (база `opensink_keystore`, хранилища `keys` и `identities`).
- **KEK** — AES-GCM-256 `CryptoKey` с `extractable: false`, usages `encrypt`/`decrypt`, создаётся один раз через `SubtleCrypto.generateKey` и хранится в IndexedDB как объект `CryptoKey` (структурное клонирование; сырой ключ KEK не попадает в дамп в aberto).
- **Гонка вкладок (критично):** `getOrCreateKek` выполняется в **одной** `readwrite` транзакции: сначала `get(_kekKey)`, при отсутствии — `add(kek, _kekKey)`. Если `add` отвергается с `ConstraintError` (другая вкладка создала KEK первыми) — повторный `get` в той же транзакции и использование чужого ключа. Без этого две вкладки создадут разные KEK и первая потеряет доступ к своим данным.
- **AAD:** при шифровании/расшифровке `IdentityBundle` дополнительные аутентифицируемые данные = имя ключа (`identity_<userId>`), закодированное как UTF-8. Это предотвращает подмену зашифрованного blob под другим именем ключа (атаку подмены контейнера).
- При `storeIdentity`: `IdentityBundle` → JSON → случайный 96-битный IV → AES-GCM-encrypt с KEK + AAD → `{version, iv, ciphertext}` в `identities`.
- При `loadIdentity`: читается `{version, iv, ciphertext}` → AES-GCM-decrypt с KEK + AAD → JSON → `IdentityBundle`. При неверном MAC/формате → `StoreCorrupted`.
- При `deleteIdentity`: запись удаляется из `identities`.
- При `hasIdentity`: проверка наличия записи в `identities`.
- **Метод `requestPersistentStorage()`:** обёртка над `navigator.storage.persist()`; возвращает `Result<bool, KeyStoreError>`. Слой 14 вызывает его при необходимости гарантировать персистентность.

#### 12.2 Модель угроз (Web)

| Угроза | Защита | Остаточный риск |
|--------|--------|-----------------|
| Чтение дампа IndexedDB (файлы браузера) | KEK — `CryptoKey` с `extractable: false`, сырой ключ не экспортируется; данные зашифрованы AES-GCM | Отсутствует (при условии, что Web Crypto API не скомпрометирован) |
| Подмена blob под другим именем ключа | AAD = имя ключа; при расшифровке с чужым AAD → `InvalidAccessError` → `StoreCorrupted` | Отсутствует |
| Порча IV / ciphertext | AEAD MAC проверяется при расшифровке → `StoreCorrupted` | Отсутствует |
| XSS (выполнение чужого JS в контексте страницы) | — | **Не защищено**: JS может вызвать `subtle.decrypt` тем же KEK и получить seed. Защита — только CSP, санитизация, изоляция. |
| Приватный режим / отключённое IndexedDB | `StoreUnavailable` с понятным текстом | Данные не сохраняются между сессиями |
| Квота IndexedDB превышена | `QuotaExceededError` → `StoreUnavailable` | Запись отклоняется |
| Нет безопасного контекста (не HTTPS/localhost) | `crypto.subtle` undefined → `StoreUnavailable` | Функциональность хранилища недоступна |
| Извлечение seed из памяти Dart после расшифровки | — | **Не защищено**: Dart не гарантирует затирание `Uint8List` (GC может копировать); seed живёт в памяти до GC |

#### 12.3 TODO(verify)

- Точные сигнатуры `SubtleCrypto.generateKey`/`encrypt`/`decrypt` и конвертация `JSPromise`→`Future`, `JSArrayBuffer`→`Uint8List` в `package:web` 0.5.1 (сверены с исходниками пакета).
- Поддержка `AesGcmParams.additionalData` в целевых браузерах (Chrome, Firefox, Safari, WebView Android).
- Работа IndexedDB + `storage.persist()` проверяется Chrome-тестами `platform_web`.
- Сборка `dart2js` и `dart2wasm` — не проверена в этом окружении.
- Работа `package:cryptography` Pbkdf2 на вебе (для опции Б — KEK из passphrase).

---

## 13. E2EE (фаза 4A — design doc, код не пишется)

Реализация поверх проверенных примитивов `package:cryptography` 2.9.0 (X25519, Ed25519, HKDF-SHA-256, XChaCha20-Poly1305). Не является Signal-совместимой (см. §13.6).

### 13.1 Prekey bundles без сервера

**Вопрос:** где берутся prekey bundles (IK, SPK, OPK) в отсутствие сервера.

**Варианты:**
- А) подписанное событие в групповом логе (слой 7/8) — запись `PrekeyAnnouncement`, подписанная Ed25519 IK;
- Б) обмен при WebRTC-рукопожатии (сигнальный канал);
- В) приглашение — bundle входит в приглашение в личный чат/группу;
- Г) иное (DHT, личный сервер) — вне scope core_crypto.

**Выбор:** В (приглашение) для личных диалогов + А (подписанное событие в групповом логе) для групп. Б — TODO(verify): WebRTC сигнальный канал не в scope core_crypto.

**One-time prekeys (OPK):** без сервера нельзя гарантировать одноразовость (нет координатора, помечающего OPK использованным). Два абонента могут взять один и тот же OPK одновременно.

**Решение:** отказ от OPK в фазе 4A — только IK + SPK (ослабленный вариант X3DH).

**Последствия:**
- Forward secrecy первого сообщения: отсутствует при компрометации долгосрочных ключей IK/SPK после доставки — shared key выводится детерминированно из долгоживущих DH-ключей.
- Replay первого сообщения: атакующий может переиграть старое приглашение с тем же SPK; получитель пересчитает тот же shared key. Защита от replay делегирована слою 3 (Envelope: nonce/sequence в заголовке) и слою 8 (подпись события); core_crypto не гарантирует её без OPK.

### 13.2 Привязка ключей (binding)

**Цель:** удостовериться, что X25519 IK и SPK принадлежат владельцу Ed25519 IK.

**Что подписывается:** SPK public key (32 байта X25519) подписывается Ed25519 private key IK.

**Контекст (domain separation):** строка `"opensink/x3dh/spk-binding/v1"` + canonical encoding SPK public key. TODO(verify): уточнить точный формат кодирования контекста (raw байты SPK или с префиксом).

**Когда проверяется:** до любого использования SPK — при приёме `X3DHPublicBundle` (в `receiver()`) и перед кэшированием bundle. Неверная подпись → bundle отбрасывается, ошибка без исключения (`InvalidPrekeyBinding` через Result/false).

**Ротация SPK:**
- Триггер: истечение TTL (например, 7 дней) или вручную пользователем; решение о rotations — слой 8.
- Механизм: новая SPK пара генерируется, подписывается IK, публикуется тем же каналом (приглашение/событие лога). Старая SPK остаётся валидной в течение grace period для недоставленных сообщений.
- Распространение без сервера: через тот же канал, что и первоначальный bundle; получатель обновляет кэш при получении новой подписанной записи.

### 13.3 Double Ratchet

База: частично реализован в `lib/src/e2ee/double_ratchet.dart` (encrypt/decrypt с chain keys + XChaCha20-Poly1305); `dhRatchetStep` — заглушка (D-06).

**KDF_RK (root key → chain keys + новый root key):**
- HKDF-SHA-256 (`GroupHkdf`, `hmac: Hmac.sha256()`, outputLength 32).
- Input: secret = DH shared secret (X25519), salt = previous root key (zero 32 байта для первого шага), info = `"opensink/double-ratchet/root-key"`.
- Output: 64 байта → 32 байта новый root key, 32 байта chain key (sending/receiving по направлению ratchet).

**KDF_CK (chain key → message key + следующая chain key):**
- HKDF-SHA-256.
- Input: secret = chain key, salt = zero 32 байта, info = `"opensink/double-ratchet/chain-key-send"` (отправитель) / `"opensink/double-ratchet/chain-key-recv"` (получатель).
- Output: 64 байта → 32 байта message key, 32 байта следующая chain key.

**AEAD:** XChaCha20-Poly1305 из фазы 2 (nonce 24, ключ 32, MAC 16). Nonce на сообщение генерируется случайно.

**AAD:** заголовок сообщения (header) + ассоциированные данные из X3DH.
- Header: версия, флаги, ephemeral public key (X25519, 32 байта), message number (uint64 LE), previous chain length (uint64 LE), optional DH public key (когда выполнен ratchet шаг).
- AAD = header bytes || X3DH associated data (для группы: `groupId || senderPeerId`; для личного: пусто, см. §1 AAD рекомендация).
- AAD не шифруется, но аутентифицируется.

**Header формат (версия 1):**
```
version(1) || flags(1) || ephemeralPK(32) || messageNumber(8 LE) || prevChainLength(8 LE) || [dhPublicKey(32) optional] || nonce(24) || ciphertext || mac(16)
```

**MAX_SKIP и пропущенные ключи:**
- Лимит: 100 пропущенных ключей на цепочку получения. При превышении — старейшие удаляются (FIFO); сообщения с номерами вне окна не расшифровываются.
- TTL: пропущенные ключи старше grace period (например, 24 часа) удаляются. TODO(verify): точное TTL и действие при истечении.
- Хранение: map message number → message key.

**Сериализация состояния для хранилища (версия 1):**
`version(uint8) || rootKey(32) || sendingChainKey(32) || receivingChainKey(32) || sendingCounter(uint64 LE) || receivingCounter(uint64 LE) || previousChainLength(uint64 LE) || dhPrivateKey(32) || dhPublicKey(32) || remoteDhPublicKey(32) || skippedKeysCount(uint16 LE) || skippedKeys...`
Неизвестная версия при загрузке → ошибка (не молчаливый отказ). Сериализация делегирована слою 3; core_crypto предоставляет `toBytes`/`fromBytes` на состояние.

**Поведение при исчерпании лимитов:** MAX_SKIP exceeded → старые skipped keys отбрасываются, такие сообщения не расшифровываются (возврат ошибки/false без исключения).

**Одновременная инициация обеими сторонами:** каждая сторона поддерживает две сессии (исходящую и входящую). При одновременной инициации каждая создаёт свою исходящую сессию через `X3DH.sender()`; при получении первого сообщения создаётся входящая через `X3DH.receiver()`. Две сессии coexist независимо; порядок внутри сессии гарантирует message number.

### 13.4 Sender Keys (группы)

**Структура:** `SenderKeyState` = chain key (32 байта) + Ed25519 signing key + sequence number (uint64) + groupId + senderPeerId.

**Раздача:** новый sender key шифруется под сессию Double Ratchet каждого члена группы (`X3DH.sender()` + AEAD) и отправляется как `SenderKeyDistributionMessage` по личному E2E-каналу. Получатель импортирует sender key и начинает использовать его для группы.

**Ротация при смене состава:** слой 8 инициирует ротацию при уходе/приходе члена; Sender генерирует новый chain key + новый signing key, раздаёт через личные каналы всем оставшимся членам; старый sender key не используется.

**Пропуски и переупорядочивание:** каждое групповое сообщение имеет sequence number (monotonically increasing). Получатель принимает seq > lastAccepted; пропущенные seq хранят в окне для переупорядочивания; старые seq или вне окна → отбрасываются.

**Окно итераций:** 100 последних sequence numbers. TODO(verify): точное значение.

**Защита от replay:** хэш-сет принятых sequence numbers в рамках окна; повтор старого seq отбрасывается.

**Подпись сообщения:** каждое групповое сообщение подписывается Ed25519 signing key sender key; подпись покрывает `ciphertext || header` (groupId, senderPeerId, sequence number). Проверка — constant-time через `Ed25519().verify`.

### 13.5 Границы

**Защищает:** содержание сообщений (confidentiality) от сетевого наблюдателя; целостность и аутентичность отправителя (AEAD + подпись); forward secrecy будущих сообщений после компрометации (при регулярном `dhRatchetStep`).

**Не защищает:** метаданные (кто с кем, размер, время) — слой 3 (Envelope/транспорт); компрометация ключа устройства (украден приватный ключ из SecureKeyStore) — платформа (flutter_secure_storage), см. §2; злонамеренный участник группы (insider) — имеет действительные ключи; обнаружение anomalies — слой 8.

**Делегировано:** слой 3 — AAD, метаданные, транспорт, replay на уровне пакетов; слой 7 — P2P доставка, WebRTC сигнальный канал; слой 8 — групповая мембершип, триггеры ротации, логи событий.

### 13.6 Отклонения от Signal

Реализация **не является Signal-совместимой**. Отклонения:
1. Нет One-Time Prekeys (OPK) — отказ в фазе 4A (§13.1).
2. IK не регистрируется на сервере — bundle передаётся напрямую (приглашение/лог).
3. AAD и заголовок Double Ratchet — собственный формат, не Noise Protocol framed как в Signal.
4. MAX_SKIP / TTL skipped keys — собственные значения (не подтверждены источником Signal — TODO(verify)).
5. Ротация Sender Keys по триггеру слоя 8, а не фиксированный интервал.
6. Сериализация состояния — собственный формат версии 1, не protobuf Signal.

### 13.3.1 Соответствие шагов спецификации Signal Double Ratchet коду

| Шаг спецификации (Signal) | Описание | Строки кода | Соответствие | Отклонение / примечание |
|---------------------------|----------|-------------|--------------|-------------------------|
| RatchetEncrypt | KDF_CK( sending_chain_key ) → message_key + next_chain_key; зашифровать с AAD=header | `double_ratchet.dart:97-112, 140-144` | ✅ | — |
| RatchetEncrypt (с ratchet-шагом) | Доп. DH-публичный ключ в заголовке (опциональное поле), флаг 0x01 | `double_ratchet.dart:80-94, 126-136` | ✅ | Ключ в опциональном поле — это **новый** DH-ключ отправителя после dhRatchetStep |
| RatchetDecrypt | Парсинг заголовка, определение флага ratchet-шага | `double_ratchet.dart:197-203` | ✅ | — |
| RatchetDecrypt (с ratchet-шагом) | DH-шаг с открытым ключом собеседника из **опционального поля** заголовка | `double_ratchet.dart:212-226` | ⚠️ | Ключ берётся из `data.sublist(optionalOffset, optionalOffset+32)` — верно |
| RatchetDecrypt | `remoteDhPublicKey` нового состояния = открытый ключ собеседника из опционального поля | `double_ratchet.dart` | ✅ | При `hasOptionalDh` берётся ключ из опционального поля, иначе из `ephemeralPkBytes`. |
| DHRatchet | X25519 shared secret + KDF_RK (salt=предыдущий rootKey, info=root-key) → новый rootKey + chain key | `double_ratchet.dart:350-395` | ✅ | salt = текущий rootKey (предыдущий перед шагом) — корректно |
| DHRatchet | Генерация новой DH-пары после шага | `double_ratchet.dart:378-380` | ✅ | — |
| SkipMessageKeys | При messageNumber > receivingMessageCounter: промежуточные ключи сохраняются в skippedKeys | `double_ratchet.dart:258-286` | ✅ | FIFO-вытеснение при length >= maxSkip, TTL-очистка |
| TrySkippedMessageKeys | messageNumber в skippedKeys → взять ключ оттуда | `double_ratchet.dart:244-249` | ✅ | — |
| Replay protection | messageNumber < receivingMessageCounter и не в skippedKeys → ошибка | `double_ratchet.dart:294-297` | ✅ | — |
| AAD | Заголовок + associated data, аутентифицируется AEAD | `double_ratchet.dart:229-230` | ✅ | — |
| Header format v1 | version(1) \|\| flags(1) \|\| ephemeralPK(32) \|\| messageNumber(8 LE) \|\| prevChainLength(8 LE) \|\| [dhPublicKey(32) optional] \|\| nonce(24) \|\| ciphertext \|\| mac(16) | `double_ratchet.dart:128-136, 200-203` | ✅ | — |
| KDF_CK info | `"opensink/double-ratchet/chain-key"` для обоих направлений | `double_ratchet.dart:101-102, 254-255` | ⚠️ | DESIGN.md §13.3 утверждает `chain-key-send` / `chain-key-recv`, но код использует единую строку. Отклонение обосновано: chain key уже разный (send/recv), info разделять не требуется (так в Signal spec). |

**Отклонение "опциональное DH-поле":** в заголовке версии 1 всегда присутствует `ephemeralPK` (32 байта, offset 2-34) — это текущий открытый DH-ключ отправителя. Опциональное поле (32 байта, offset 50-82, флаг 0x01) присутствует **только** когда выполнен dhRatchetStep и содержит **новый** открытый DH-ключ отправителя. Получатель обязан сохранить ключ из опционального поля как `remoteDhPublicKey`, иначе следующая отправка с ratchet-шагом использует неверный удалённый ключ.

### 13.3.2 Атомарность и DoS

`decrypt()` не мутирует `this.skippedKeys` до успешной AEAD-расшифровки: изменения
собираются во временную копию и применяются только к следующему состоянию.
`messageNumber` и `previousChainLength` валидируются до цикла пропуска;
`_maxMessageNumber = 1 << 30`, `maxSkip = 100` с FIFO-вытеснением, TTL 24 часа.

### 13.3.3 Проверяемые сценарии

- X3DH roundtrip: `generateKeyBundle → sender → receiver` дают одинаковый shared key (без OPK).
- X3DH binding: подмена SPK public key без переподписи → `verifyBinding` false.
- X3DH вектор на известных данных из спецификации (источник — TODO(verify)).
- Double Ratchet encrypt/decrypt roundtrip: одно и несколько сообщений подряд.
- Double Ratchet пропущенные сообщения: отправка 1..10, получение 1,3,10 — ключи 2,4–9 skipped; 3 и 10 расшифруются, 2 — нет (если вне окна).
- Double Ratchet `dhRatchetStep`: после DH шага новые root/chain ключи; старые сообщения не расшифруются.
- Double Ratchet одновременная инициация: обе стороны вызывают `sender()`, обмениваются первым сообщением, обе расшифровывают сообщения друг друга.
- Double Ratchet неверный MAC/AAD → `DecryptionFailed`, не исключение.
- Сериализация состояния: `toBytes`/`fromBytes` версии 1; неизвестная версия → ошибка.
- Sender Keys: генерация, подпись, verify; ротация — старый key не принимает новые сообщения.
- Sender Keys replay: сообщение с уже принятым sequence number отбрасывается.
- Sender Keys распределение: шифрование под Double Ratchet сессию каждого члена, импорт получателем.
- `toString()` не раскрывает секреты (Double Ratchet state, Sender Key state).

---
## 14. Архитектура защиты от replay (слои 3 / 5 / 7)

core_crypto обеспечивает криптографическую целостность и аутентичность, но **не** отслеживает использованные nonce/sequence на уровне AEAD:

- **AEAD (XChaCha20-Poly1305)** — stateless: тот же шифртекст с тем же ключом и nonce расшифровывается многократно. Replay на этом уровне не обнаруживается (характеризован в `test/replay_test.dart`).
- **Double Ratchet** — replay protection на уровне номера сообщения в рамках приёмной цепочки: `messageNumber < receivingMessageCounter` и не в `skippedKeys` → `DecryptionFailed`; окно пропущенных ключей `maxSkip = 100` с FIFO-вытеснением и TTL 24ч (DESIGN.md §13.3).
- **Sender Keys** — replay protection на уровне `sequenceNumber` отправителя: `SenderKeyState.acceptSequence` отклоняет повтор и слишком старые номера в окне `_maxWindow = 100` (DESIGN.md §13.4).

Где именно находится защита от replay событий и signaling:

| Слой | Что защищает от replay | Механизм |
|------|----------------------|----------|
| Слой 3 (Envelope) | Сетевые пакеты: повтор доставки одного и того же конверта | nonce / sequence number в заголовке конверта; AEAD AAD покрывает заголовок |
| Слой 5 (core_crypto) | Double Ratchet и Sender Keys | Номер сообщения в цепочке приёма; окно skipped keys; `acceptSequence` |
| Слой 7 (P2P доставка) | Повтор доставки события/приглашения в групповом логе | Идентификатор события, дедупликация по логу (слой 8) |
| Слой 8 (членство, логи) | Ротация ключей, отзыв, replay старых приглашений | TTL, grace period, триггеры ротации SPK/sender key |

core_crypto не гарантирует защиту от replay на транспортном уровне — это задача слоёв 3/7/8.

---
## 15. Хранение состояний E2EE при покое (фаза F5)

Сериализованные состояния Double Ratchet и Sender Key содержат секретные цепочки ключей (root key, chain keys, пропущенные ключи, ключи подписи). Если такие байты положить в хранилище (drift: SQLite / OPFS) как есть, компрометация диска или профиля браузера ломает защиту E2EE. StateVault решает эту проблему: запечатывает (seal) состояние перед записью и вскрывает (open) после чтения.

### 15.1 StateVault (core_crypto)

`StateVault` предоставляет два метода, оба возвращают `VaultResult<T>` (sealed classes, без исключений):

- `seal(Uint8List plaintext, StateVaultContext context) -> Future<VaultResult<SealedState>>`
- `open(SealedState sealed, StateVaultContext context) -> Future<VaultResult<Uint8List>>`

**Ключ хранилища:**
- Независимый случайный 256-битный ключ, создаётся при первом вызове `seal`.
- Хранится в `SecureKeyStore` под ключом `opensink_state_vault_v1`.
- **Не выводится из identity seed.** Обоснование: ключ хранилища и ключ идентичности имеют разные жизненные циклы. Если пользователь rotating-ит идентичность, ключ хранилища может остаться прежним (или быть удалён независимо). Выведение из identity seed связало бы их жёстко и усложнило ротацию.
- **Последствия потери ключа:** все сохранённые сессии E2EE (Double Ratchet и Sender Key) становятся нерасшифруемыми. Пользователю придётся устанавливать сессии заново (новый X3DH handshake, повторная раздача Sender Keys). Это принятый остаточный риск.

**Конверт (версия 1):**
```
version(1) || kind(1) || stateIdLen(2 LE) || stateId(stateIdLen) ||
nonce(24) || ciphertext || mac(16)
```

**AAD:**
```
utf8("opensink/state/v1") || kind(1) || stateIdLen(2 LE) || stateId(stateIdLen) || context.formatVersion(1)
```

AAD связывает зашифрованное тело с контекстом: подмена `kind`, `stateId` или `formatVersion` между `seal` и `open` приводит к `OpenFailed`. `open()` дополнительно проверяет заголовок конверта (version, kind, stateId) перед расшифровкой — это обнаруживает порчу байтов заголовка, которые не покрываются AEAD-телом.

**AEAD:** XChaCha20-Poly1305 (фаза 2), nonce 24 байта (генерируется случайно), MAC 16 байт. Разные `seal` одного состояния производят разные шифртексты (случайный nonce).

`SealedState.toString()` не раскрывает содержимое конверта (только длины и метаданные).

### 15.2 EncryptedStateStore (core_domain)

Интерфейс для хранения запечатанных blob:

```dart
abstract class EncryptedStateStore {
  Future<Result<Uint8List, EncryptedStateStoreError>> load(String id);
  Future<Result<void, EncryptedStateStoreError>> save(String id, Uint8List sealed);
}
```

Реализация в `core_storage` (drift: SQLite / OPFS) — вне этой фазы.

### 15.3 Контракт транзакционности (слои 4 и 7)

Состояние ratchet и принятое событие сохраняются в **одной транзакции** хранилища. Это гарантирует: либо оба изменения применяются, либо ни одного.

**Последствия сбоя между расшифровкой и записью:**
- Если состояние расшифровано, но запись в хранилище не удалась — ключ сообщения считается потерянным (ratchet цепочка продвинулась, но состояние не сохранено). Повтор того же сообщения не расшифруется.
- Политика: приложение логирует сбой без раскрытия ключей и предлагает пользователю повторную синхронизацию сессии.

### 15.4 Защита от подмены состояния (rollback)

Атака: подменить текущую запись в хранилище старой версией состояния → повторное использование ключей цепочки (break of forward secrecy для старых сообщений).

**Решение в этой фазе:** НЕ реализовано. Полная защита требует монотонного счётчика в защищённом хранилище (например, в SecureKeyStore или отдельном защищённом счётчике), который инкрементируется при каждой записи и проверяется при чтении.

**Остаточный риск:**атакующий с доступом к хранилищу может подменить состояние старой версией, что приведёт к повторному использованию ключей. Для компромисса достаточно: атакующий должен иметь доступ к файлам хранилища (уровень устройства/браузера), и атака обнаружится на следующем сообщении (номер сообщения не совпадёт). Подлежит пересмотру в следующей фазе (требуется защищённый монотонный счётчик).


