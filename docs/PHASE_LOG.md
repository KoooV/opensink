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
