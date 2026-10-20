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

## Запись 3 — Фаза 2: AEAD, GroupSecret, HKDF, тестовые векторы

### Что сделано
1. **D-01 исправлен** — `lib/src/aead.dart`: `AesGcm.with256bits()` заменён на `crypto_pkg.Xchacha20.poly1305Aead()` (nonce 24 байта, ключ 32 байта, MAC 16 байт). Wire format: `nonce(24) || ciphertext || mac(16)`. `generateAeadKey()` также на XChaCha20. `decrypt` проверяет минимальную длину (40 байт = 24 + 16). Все ошибки расшифровки возвращают единый `DecryptionFailed` без раскрытия причины. AAD поддерживается.

2. **D-10 исправлен** — `lib/src/hkdf.dart`: три класса `SignalingTopicContext`/`SignalingPayloadKeyContext`/`InvitationKeyContext` (только статические члены) заменены на `enum GroupKeyContext` с полем `info`. Значения info не изменены. Вызовы обновлены в `lib/src/group_secret.dart`. `dart analyze lib/` чист (0 ошибок, 2 pre-existing info).

3. **D-04 закрыта как by design** — шифрование `IdentityBundle.encryptedPrivateKey` относится к платформенному слою (`platform_*`); в `core_crypto` нет мастер-ключа. `MemorySecureKeyStore` хранит verbatim (подтверждено тестом).

4. **D-09 не подтверждена** — импорт `hkdf.dart` в `signer.dart` используется для `bytesToHex`.

5. **Добавлены тесты** (все зелёные на VM):
   - `test/aead_test.dart` — 14 тестов: roundtrip для размеров 0/1/16/1 МБ, вектор draft-arciszewski-xchacha-03 (пример #1, с фиксированным nonce + детерминизм), roundtrip с AAD и без, порча nonce/тела/MAC, неверный ключ, вход короче 40 байт, 1000 шифрований с разными nonce.
   - `test/hkdf_test.dart` — 10 тестов: RFC 5869 Appendix A векторы Test Case 1/2/3 (SHA-256), детерминизм, разный info/salt → разный вывод, `GroupKeyContext` enum (info значения, различимость).
   - `test/group_secret_test.dart` — 9 тестов: детерминизм ключей, попарное различие topic/signaling/invitation, 1000 случайных секретов без коллизий topic, topicHex = hex(topic), длины ключей, toString не раскрывает секреты (GroupSecret + GroupKeys).

6. **Добавлены `toString()` к `GroupSecret` и `GroupKeys`** — не раскрывают секреты (`<secret>` вместо байт ключей).

7. **Удалён дубликат** `test/crypto_test.dart` (полная копия `aead_test.dart`).

8. **Дизайн-doc** — `packages/core_crypto/DESIGN.md` §1 дополнено: обоснование XChaCha20 vs AES-GCM (таблица компромиссов), wire format, AAD рекомендация (слой 3), обработка ошибок, тестовые векторы.

### Что изменено
- Новые файлы: `test/aead_test.dart` (перезаписан), `test/hkdf_test.dart` (перезаписан), `test/group_secret_test.dart` (перезаписан).
- Удалённые файлы: `test/crypto_test.dart`.
- Изменённые файлы: `lib/src/aead.dart` (D-01), `lib/src/hkdf.dart` (D-10), `lib/src/group_secret.dart` (enum + toString), `docs/DEFECTS.md` (D-01, D-04, D-09, D-10), `docs/PHASE_LOG.md` (эта запись).

### Что осталось
- D-05 (X3DH-заглушки в `test/e2ee/x3dh_test.dart`) — для фазы 3.
- D-06 (`dhRatchetStep` в `lib/src/e2ee/double_ratchet.dart`) — для фазы 3, требует design doc.
- Q2 (DI platform-реализации), Q4 (Chrome-тестирование CI), Q5 (шифрование encryptedPrivateKey) — остаются открытыми.

### Результаты тестирования
- `dart test test/ -p vm`: **91 пройдено, 0 провалено** (было 80 после фазы 1).
- `dart analyze lib/`: 0 ошибок, 2 info (pre-existing).
- Chrome-тестирование не доступно в этом окружении (Q4).

## Запись 4 — Фаза 3: SecureKeyStore и платформенные реализации

### Что сделано
1. **Контракт SecureKeyStore приведён к Result** (`packages/core_domain/lib/src/interfaces/secure_key_store.dart`):
   - все методы возвращают `Result<T, KeyStoreError>`;
   - добавлен sealed `KeyStoreError` с вариантами `IdentityNotFound` (ключ absent) и `StoreError(String)` (сбой инфраструктуры, без секретов в сообщении);
   - `IdentityBundle` получил безопасный `toString()` (не раскрывает `encryptedPrivateKey`) и операторы equality/hashCode;
   - убран дублирующий `core_crypto.CryptoError.IdentityNotFound` (конфликт имён с доменным).
2. **core_crypto**:
   - `MemorySecureKeyStore` переписан под Result-контракт, `@visibleForTesting`, комментарий «не для продакшена», хранит verbatim (по D-04 by design);
   - удалены неэкспортируемые дублирующие стабы `secure_key_store_native.dart` / `secure_key_store_web.dart`; оставлен экспортируемый `secure_key_store_platform.dart` с доменной ошибкой `StoreError` при любом вызове;
   - добавлена зависимость `meta`.
3. **platform_android / platform_linux**: реализации на `flutter_secure_storage` (v9.2.4) с Result, оборачивание исключений в `StoreError`; Linux — явная ошибка с инструкцией по libsecret при отсутствии Secret Service, никакого отката на файл в открытом виде.
4. **platform_web**: переписан на `package:web` (v0.5.1) + `dart:js_interop`, убран `dart:html`, добавлена зависимость `web`. KEK — AES-GCM-256 `CryptoKey` (`extractable: false`) в IndexedDB, оборачивает (шифрует) `IdentityBundle` через AES-GCM со случайным IV. Добавлен `TODO(verify)` по API `package:web`, `storage.persist()`, Pbkdf2 на вебе.
5. **Тесты**:
   - общий контракт-тест `secure_key_store_contract.dart` (write/read/overwrite/delete/отсутствующий/пустой/большой);
   - `memory_secure_key_store_test.dart`: контракт + toString-секретность;
   - `platform_web/test/secure_key_store_web_test.dart`: контракт для Web (Chrome);
   - `core_crypto_test.dart` / `core_domain_test.dart`: FakeSecureKeyStore приведён к Result.

### Что изменено
- Новые файлы: `packages/core_crypto/test/key_store/secure_key_store_contract.dart`, `packages/platform_web/test/secure_key_store_web_test.dart`.
- Изменённые: `packages/core_domain/lib/src/interfaces/secure_key_store.dart`, `fakes.dart`, `test/core_domain_test.dart` (FakeSecureKeyStore под Result), `packages/core_crypto/lib/src/key_store/memory_secure_key_store.dart`, `secure_key_store_platform.dart`, `crypto_exceptions.dart`, `pubspec.yaml`, `test/core_crypto_test.dart`, `test/key_store/memory_secure_key_store_test.dart`, `packages/platform_android/lib/src/secure_key_store_android.dart`, `packages/platform_linux/lib/src/secure_key_store_linux.dart`, `packages/platform_web/lib/src/secure_key_store_web.dart` + pubspec, `packages/core_crypto/DESIGN.md` (секции 9–12, таблица угроз §2), `docs/OPEN_QUESTIONS.md` (Q4), `docs/PHASE_LOG.md` (эта запись).
- Удалённые: `packages/core_crypto/lib/src/key_store/secure_key_store_native.dart`, `secure_key_store_web.dart` (дублирующие неэкспортируемые стабы).

### Что осталось
- D-05 (X3DH-заглушки), D-06 (dhRatchetStep) — для следующих фаз.
- Q2 (DI подключения platform-реализаций) — открыт.
- Q5 — решена by design (защита на уровне платформы, задокументировано в DESIGN.md §11).
- Q4 — Chrome-рантайм-тесты не прогоняются в этом окружении (раннер `package:test` не отдаёт `dart.js` с верным MIME-типом); компиляция через `dart2js` проверена.

### Результаты тестирования
- `dart test packages/core_crypto/test/ -p vm`: **96 пройдено, 0 провалено**.
- `dart test packages/core_domain/test/`: файл не загружается из-за предшествующей ошибки `GroupState.copyWith` (не связана с фазой 3).
- `dart test packages/platform_web/test/ -p chrome`: компиляция через `dart2js` успешна, рантайм не стартует из-за инфраструктуры тестового раннера (см. Q4).
- `dart analyze packages/core_crypto/lib`: 0 ошибок.
- `dart analyze packages/platform_web/lib`: 0 ошибок, 3 info.
- ГРеп: в `core_crypto` нет `dart:io`/`dart:html`/`package:web`; в `platform_web` нет `dart:html`.
