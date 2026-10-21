# Design doc: проект opensink (общий)

## Верified API

Таблица проверенных API фиксируется в пакете `packages/core_crypto/DESIGN.md` (§6 «Verified API», package:cryptography 2.9.0, Dart 3.13.5). Проверено spike-тестами в `packages/core_crypto/spike/api_spike_test.dart`.

| Что проверено | Как вызывается (код) | VM | Chrome | Вывод |
|---------------|----------------------|----|--------|-------|
| Ed25519 ключевая пара из seed | `Ed25519().newKeyPairFromSeed(seed)` → `extractPublicKey()` / `extractPrivateKeyBytes()` | ✅ | — | Публичный ключ парен приватному; детерминистичен. |
| Ed25519 sign/verify | `Ed25519().sign(data, keyPair: kp)` → `Signature.bytes` (64); `verify(data, signature: sig)` | ✅ | — | Roundtrip проходит; чужие данные не проходят. |
| X25519 DH | `X25519().newKeyPairFromSeed(seed)` → `sharedSecretKey()` → `extractBytes()` | ✅ | — | Два участника получают идентичный 32-байтный секрет. |
| XChaCha20-Poly1305 | `Xchacha20.poly1305Aead()`; nonceLength 24, secretKeyLength 32, MAC 16 | ✅ | — | Неверный MAC → `SecretBoxAuthenticationError`. |
| HKDF (RFC 5869) | `Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(secretKey:, nonce:, info:)` | ✅ | — | Выход 32 байта. |
| PBKDF2 | `Pbkdf2(macAlgorithm: Hmac.sha512(), iterations: 2048, bits: 512).deriveKey(secretKey:, nonce:)` | ✅ | — | Выход 512 бит (64 байта). |

Chrome в данном окружении отсутствует — проверка только на VM (см. docs/OPEN_QUESTIONS.md Q4).

## Ссылки

- `packages/core_crypto/DESIGN.md` — полный design doc core_crypto (AEAD, SecureKeyStore, E2EE, BIP-39, Identity, replay).
- `docs/DEFECTS.md` — реестр дефектов core_crypto.
- `docs/OPEN_QUESTIONS.md` — открытые вопросы (включая Q12–Q19 из TODO(verify) в других пакетах).
- `docs/PHASE_LOG.md` — журнал фаз разработки.
