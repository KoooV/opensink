# PHASE_LOG — core_crypto

## Запись 1 — Фаза 0: базовая линия и API-spike

### Что сделано
1. **Baseline зафиксирован** (working tree приведён к committed-состоянию, `git diff packages/core_crypto/lib` пуст):
   - `package:cryptography` **2.9.0**, `flutter_secure_storage` **9.2.4**, Dart SDK **3.13.5**.
   - `dart analyze`: 24 ошибки (все в `test/` — `unused_import`, `prefer_const_constructors`), 1 warning, 5 info; в `lib/` — 0 ошибок.
   - `dart test test/`: **53 пройдено, 0 провалено**.
   - Spike-тесты в `packages/core_crypto/spike/api_spike_test.dart`: **7 пройдено, 0 провалено** (запускаются отдельно: `dart test spike/`, не входят в основной прогон).

2. **Документы созданы**:
   - `docs/DEFECTS.md` — реестр дефектов (D-01…D-10) со статусами.
   - `docs/OPEN_QUESTIONS.md` — открытые вопросы (Q1…Q5).
   - `docs/PHASE_LOG.md` — эта запись.

3. **Spike API-верификация package:cryptography 2.9.0** (успешна):
   - а) `Ed25519().newKeyPairFromSeed(seed)` — открытый ключ соответствует приватному, вызов с тем же seed детерминистичен, sign/verify roundtrip проходит.
   - б) `X25519.newKeyPairFromSeed` + `sharedSecretKey()` — два участника получают одинаковый 32-байтный секрет.
   - в) `Xchacha20.poly1305Aead()` — `nonceLength == 24`, `secretKeyLength == 32`, MAC 16 байт, неверный MAC → `SecretBoxAuthenticationError`.
   - г) `Hkdf(hmac: Hmac.sha256(), outputLength: 32)` с `nonce`/`info`; `Pbkdf2(macAlgorithm: Hmac.sha512(), iterations: 2048, bits: 512)`.
   - д) Chrome в окружении отсутствует; проверка только на VM (Q4).

### Что изменено
- Новых файлов: `docs/DEFECTS.md`, `docs/OPEN_QUESTIONS.md`, `docs/PHASE_LOG.md`, `packages/core_crypto/spike/api_spike_test.dart`.
- Изменений в `lib/` и `test/` нет.

### Что осталось
- Таблица «Verified API» должна быть добавлена в `packages/core_crypto/DESIGN.md` (см. требование приёмки фазы 0).
- Решение об исправлении дефектов D-01…D-06 и миграции версии откладывается на следующую фазу.

### Вывод по миграции cryptography
Миграция на другую версию `package:cryptography` **не требуется**: все примитивы, нужные для устранения подтверждённых дефектов, уже доступны в зафиксированной 2.9.0 (подтверждено spike-тестами а–г). Дефекты устраняются на уровне кода `core_crypto`, а не версии зависимости.

## Запись 2 — Фаза 1: Signer, Identity, мнемоника

### Что сделано
1. **D-02 исправлен** — `CryptoSigner.sign()` теперь восстанавливает ключевую пару через `Ed25519().newKeyPairFromSeed(privateKeyBytes)` вместо подмены публичного ключа временной парой. `verify()` ловит все `Exception`/`Error` и возвращает `false` на некорректный ввод (не-hex, неверная длина, пустая подпись, неверная длина ключа в PeerId).
2. **D-03 исправлен** — `recoverIdentityFromMnemonic()` теперь использует `Ed25519().newKeyPairFromSeed(edMaterial)` и `X25519().newKeyPairFromSeed(xMaterial)`; публичные ключи производятся из тех же seed, что и приватные. Добавлен binding: X25519 public key подписывается Ed25519 private key, метод `CryptoIdentity.verifyBinding()`.
3. **Добавлен design doc** в `packages/core_crypto/DESIGN.md` (§8: Identity и мнемоника — выбор 12-словного BIP-39, PBKDF2-HMAC-SHA512 seed, HKDF-SHA256 с versioned info, binding, domain separation, toString secrecy, замер PBKDF2 ~33.6 ms на VM).
4. **Новые тесты**:
   - `test/signer_test.dart` — 14 тестов: roundtrip, 1 бит данных, чужой PeerId, усечённая/удлинённая подпись, пустые данные, не-hex, пустая подпись, чужой ключ, неверная длина PeerId, RFC 8032 §7.1 TEST 1 и TEST 2 (векторы из спецификации), детерминизм, regression D-02.
   - `test/identity_test.dart` — 23 теста: структура identity, детерминизм восстановления, разные мнемоники → разные ключи, подпись и X25519 DH восстановленной identity, verifyBinding, подмена X25519 ключа, отсутствие подписи, BIP-39 официальный вектор (abandon×11+about, passphrase TREZOR), детерминизм seed, разные passphrase, валидация мнемоники (checksum, неизвестное слово, длина, пробелы, регистр), toString не раскрывает секреты.
5. **Замер PBKDF2**: ~33.6 ms на VM (2048 итераций, SHA-512, 512 бит). Chrome-замер отложен (Q4).

### Что изменено
- Новые файлы: `packages/core_crypto/test/signer_test.dart`, `packages/core_crypto/test/identity_test.dart`.
- Изменённые файлы: `packages/core_crypto/lib/src/signer.dart` (D-02), `packages/core_crypto/lib/src/identity.dart` (D-03 + binding), `packages/core_crypto/DESIGN.md` (§8), `docs/DEFECTS.md` (D-02, D-03 → исправлено), `docs/PHASE_LOG.md` (эта запись).

### Что осталось
- D-01 (AEAD XChaCha20 вместо AES-GCM), D-04 (шифрование encryptedPrivateKey), D-05 (X3DH-тесты), D-06 (dhRatchetStep), D-09 (unused import — теперь использован, статус требует пересмотра), D-10 (статические классы) — остаются для следующих фаз.
- Q2 (DI platform-реализации), Q4 (Chrome-тестирование CI), Q5 (гарантии шифрования) — остаются открытыми.

### Результаты тестирования
- `dart test test/ -p vm`: **80 пройдено, 0 провалено** (было 53 до фазы 1).
- `dart test test/signer_test.dart test/identity_test.dart -p chrome`: **37 пройдено, 0 провалено**.
- `dart analyze lib/`: 5 info-уровня (все pre-existing, D-10 уже в реестре).
