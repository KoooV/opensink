# Открытые вопросы core_crypto (фундамент 0)

## Q1 — Миграция package:cryptography
Версия зафиксирована 2.9.0. Spike подтвердил, что все нужные примитивы доступны в 2.9.0:
- `Ed25519().newKeyPairFromSeed(seed)` — работает, детерминизм соблюдается.
- `X25519().newKeyPairFromSeed(seed)` + `sharedSecretKey()` — работает.
- `Xchacha20.poly1305Aead()` — nonceLength 24, secretKeyLength 32, MAC 16, ошибка `SecretBoxAuthenticationError` при неверном MAC.
- `Hkdf(hmac, outputLength)` с `nonce`/`info`; `Pbkdf2(macAlgorithm, iterations, bits)`.
Вывод: миграция на другую версию `cryptography` **не требуется** для устранения подтверждённых дефектов (см. PHASE_LOG и ответ ниже).

## Q2 — Платформенная реализация SecureKeyStore
Реальные реализации (Keystore/libsecret/Web Crypto API + IndexedDB) вынесены в `platform_*` пакеты. В `core_crypto` остаются только stub (`secure_key_store_platform.dart`) и `MemorySecureKeyStore`. Вопрос: механизм подключения/platform-реализации через DI — уточнить в следующей фазе.

## Q3 — dhRatchetStep
`DoubleRatchet.dhRatchetStep` бросает `UnimplementedError`. Примитивы (`X25519.sharedSecretKey`, `newKeyPairFromSeed`) доступны в 2.9.0, реализация возможна, но требует отдельного design-документа (Double Ratchet шаг). Отложено на следующую фазу.

## Q4 — Chrome-тестирование
В этом окружении нет браузера Chrome/Chromium; spike-тесты прогонялись только на VM. Поведение на Chrome (включая `Xchacha20.poly1305Aead` через Web Crypto API, если такая дорога будет выбрана) требует проверки в CI с `dart test -p chrome`.

## Q5 — encryptedPrivateKey гарантии
`IdentityBundle.encryptedPrivateKey` named "encrypted", но код не гарантирует шифрование; `MemorySecureKeyStore` хранит в открытом виде. Нужно ли добавлять обязательное шифрование на уровне core_crypto, или шифрование полностью platform-специфично — открыто.
