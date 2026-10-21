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
| Android | flutter_secure_storage → Keystore (v9.2.4) | Дамп файловой системы, доступ из других приложений; ключи изолированы Keystore/StrongBox (когда доступен) | Root-доступ компрометирует хранилище; StrongBox не гарантирован на всех устройствах; Google Auto Backup может экспортировать ключи; ключи не восстанавливаются при переносе на новое устройство | Хранит IdentityBundle как зашифрованный blob через flutter_secure_storage. При ошибке хранилища — `StoreError` с понятным сообщением, без тихого отката на файл в открытом виде. |
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

Зависимость: `bip39: ^3.0.0` (проверенная библиотека, стандартная в экосистеме Flutter/Dart).

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

PBKDF2-HMAC-SHA-512 (2048 итераций, 512 бит) на VM: ~33.6 ms на одну derived-ключ (10 итераций в среднем, Dart VM, без JIT-прогрева после первого вызова). Измерено скриптом `tool/pbkdf2_bench.dart`. Chrome-замер отложен (см. docs/OPEN_QUESTIONS.md Q4).

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

Переименование `encryptedPrivateKey` → `privateSeed` не выполнено: поле действительно защищено шифрованием, не appearing на уровне платформы, а не внутри `core_crypto`. В DESIGN.md задокументировано, что защита обеспечивается хранилищем платформы.

### 12. Web-реализация (platform_web, фаза 3)

Переписана на `package:web` (v0.5.1) + `dart:js_interop`; `dart:html` удалён.

Дизайн:
- При инициализации открывается IndexedDB (база `opensink_keystore`, хранилища `keys` и `identities`).
- KEK — AES-GCM-256 `CryptoKey` с `extractable: false`,usage `wrapKey | unwrapKey`, генерируется один раз и хранится в IndexedDB как объект `CryptoKey` (структурное клонирование; сырой ключ не появляется в дампе в aberto).
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
| RatchetDecrypt | `remoteDhPublicKey` нового состояния = открытый ключ собеседника из опционального поля | `double_ratchet.dart:324-327` | ❌ | **БАГ**: записывается `ephemeralPkBytes` (offset 2-34, ключ отправителя из фиксированной части), а не ключ из опционального поля |
| DHRatchet | X25519 shared secret + KDF_RK (salt=предыдущий rootKey, info=root-key) → новый rootKey + chain key | `double_ratchet.dart:350-395` | ✅ | salt = текущий rootKey (предыдущий перед шагом) — корректно |
| DHRatchet | Генерация новой DH-пары после шага | `double_ratchet.dart:378-380` | ✅ | — |
| SkipMessageKeys | При messageNumber > receivingMessageCounter: промежуточные ключи сохраняются в skippedKeys | `double_ratchet.dart:258-286` | ✅ | FIFO-вытеснение при length >= maxSkip, TTL-очистка |
| TrySkippedMessageKeys | messageNumber в skippedKeys → взять ключ оттуда | `double_ratchet.dart:244-249` | ✅ | — |
| Replay protection | messageNumber < receivingMessageCounter и не в skippedKeys → ошибка | `double_ratchet.dart:294-297` | ✅ | — |
| AAD | Заголовок + associated data, аутентифицируется AEAD | `double_ratchet.dart:229-230` | ✅ | — |
| Header format v1 | version(1) \|\| flags(1) \|\| ephemeralPK(32) \|\| messageNumber(8 LE) \|\| prevChainLength(8 LE) \|\| [dhPublicKey(32) optional] \|\| nonce(24) \|\| ciphertext \|\| mac(16) | `double_ratchet.dart:128-136, 200-203` | ✅ | — |
| KDF_CK info | `"opensink/double-ratchet/chain-key"` для обоих направлений | `double_ratchet.dart:101-102, 254-255` | ⚠️ | DESIGN.md §13.3 утверждает `chain-key-send` / `chain-key-recv`, но код использует единую строку. Отклонение обосновано: chain key уже разный (send/recv), info разделять не требуется (так в Signal spec). |

**Отклонение "опциональное DH-поле":** в заголовке версии 1 всегда присутствует `ephemeralPK` (32 байта, offset 2-34) — это текущий открытый DH-ключ отправителя. Опциональное поле (32 байта, offset 50-82, флаг 0x01) присутствует **только** когда выполнен dhRatchetStep и содержит **новый** открытый DH-ключ отправителя. Получатель обязан сохранить ключ из опционального поля как `remoteDhPublicKey`, иначе следующая отправка с ratchet-шагом использует неверный удалённый ключ.

### 13.3.2 Закрытие гипотезы «баг стр. 324-327»

**Гипотеза:** `remoteDhPublicKey` следующего состояния берётся из `ephemeralPkBytes` заголовка, а не из опционального DH-поля.

**Статус:** **подтверждён как баг.** В `decrypt()` (строки 324-327) `remoteDhPublicKey` всегда устанавливается в `ephemeralPkBytes` (offset 2-34 — текущий DH-ключ отправителя), даже когда флаг 0x01 установлен и в опциональном поле передан новый ключ. При次の encrypt с `remotePublicKey` вызывающий код должен сам передать корректный удалённый ключ, но состояние `remoteDhPublicKey` в объекте состояния не отражает реальный последний ключ собеседника.

**Исправление:** когда `hasOptionalDh`, `remoteDhPublicKey` берется из опционального поля (offset `optionalOffset`..`optionalOffset+32`); иначе — из `ephemeralPkBytes`.

### 13.3.3 Атомарность и DoS

**Атомарность:** `decrypt()` не должен мутировать `this.skippedKeys` до успешной AEAD-расшифровки. В текущей реализации пропущенные ключи добавляются в `this.skippedKeys` (ссылка на ту же карту) в цикле пропуска (строки 275-283) до проверки AEAD (строка 300). При неудаче расшифровки состояние вызывающего уже изменено — нарушение атомарности.

**Исправление:** все изменения `skippedKeys` собираются во временную копию; следующее состояние получает копию только при успехе. При ошибке `this` не меняется, `toBytes()` до и после неудачного `decrypt()` идентичны.

**DoS:** `messageNumber` и `previousChainLength` из заголовка валидируются перед циклом пропуска. `messageNumber` ограничен протокольным максимумом (`_maxMessageNumber`), что отсекает absurdные значения (например 2^31) до любой аллокации в цикле. Общий лимит пропущенных ключей задан `maxSkip` (100) с FIFO-вытеснением; TTL (24ч) удаляет уставшие записи.

### 13.7 План тестов (сценарии, без реализации)

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

