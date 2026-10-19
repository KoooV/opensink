# Design doc: core_crypto

## 1. AEAD: XChaCha20-Poly1305

**Выбор:** `XChaCha20-Poly1305` (через `package:cryptography` `XChaCha20Poly1305`).

**Обоснование:**
- **Nonce misuse resistance.** В P2P-сети нет центрального координатора для отслеживания использованных nonce. XChaCha20-Poly1305 использует 192-битный nonce, который можно генерировать случайно без риска коллизии при Geburtstag-парадоксе (в отличие от 96-битного nonce AES-GCM).
- **Поддержка на Web:** Web Crypto API не поддерживает XChaCha20-Poly1305 нативно, но `package:cryptography` реализует его на чистом Dart, что работает одинаково на всех платформах.
- **Производительность на мобильных:** ChaCha20 быстрее AES на устройствах без AES-NI (многие Android-телефоны, эмуляторы).
- **Не изобретаем примитивы:** используем готовую реализацию из `package:cryptography`.

**Альтернатива (отклонена):** AES-GCM — требует строгого учета nonce (96 бит), уязвим к полному раскрытию ключа при повторе nonce, нативная поддержка на Web есть, но риск ошибки в P2P-среде слишком высок.

## 2. SecureKeyStore: гарантии по платформам

| Платформа | Реализация | Хранение | Извлекаемость | Слабые стороны |
|-----------|-----------|----------|---------------|----------------|
| Android | flutter_secure_storage → Keystore | TEE/StrongBox (если доступно), иначе soft-keystore | Нет (неизвлекаемые ключи) | Root-доступ комроментирует хранилище; нет гарантии StrongBox на всех устройствах; бэкап в Google Drive может экспортировать ключи |
| Linux | flutter_secure_storage → libsecret / secret-service | Сеансовый démon, зашифровано паролем сеанса | Нет (через Opaque API) | Нет TEE; тот же пользователь/root может прочитать; зависит от окружения рабочего стола |
| Web | Web Crypto API + IndexedDB | IndexedDB (зашифрованный ключ), ключ в CryptoKey (extractable: false) | Нет (неизвлекаемый из WebCrypto) | XSS крадёт ключи через JS-контекст; IndexedDB не зашифрован на диске браузера; уязвимости браузера; нет аппаратного изоляции |

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

