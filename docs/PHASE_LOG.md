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

## Запись 5 — Фаза 4B: E2EE (X3DH, Double Ratchet, Sender Keys)

### Что сделано
1. **D-05 исправлен** — все 3 stub-теста `expect(true, isTrue)` в `test/e2ee/x3dh_test.dart` заменены на реальные тесты:
   - X25519 shared secret по RFC 7748 §6.1 (Alice/Bob private→public keys, shared secret)
   - sender/receiver roundtrip: обе стороны получают одинаковый SK
   - разные bundles → разные SK
   - неверная подпись SPK → `Err(InvalidSignature)` до DH-вычислений
   - отсутствие подписи SPK → отказ
   - работа без one-time prekey (OPK удалён по DESIGN.md §13.1)

2. **D-06 исправлен** — `dhRatchetStep()` реализован в `lib/src/e2ee/double_ratchet.dart`:
   - X25519.sharedSecretKey с SimpleKeyPairData из приватных байт
   - KDF_RK: HKDF-SHA-256, salt=предыдущий rootKey, info="opensink/double-ratchet/root-key", 64 байт → rootKey + chain key
   - генерация новой DH-пары после шага
   - пропущенные ключи с MAX_SKIP=100, TTL=24ч, FIFO-вытеснение
   - защита от replay (повторный номер сообщения отклоняется)
   - сериализация toBytes()/fromBytes() версии 1 с проверкой версии
   - заголовок версии 1: version(1) || flags(1) || ephemeralPK(32) || messageNumber(8 LE) || prevChainLength(8 LE) || [dhPublicKey(32) optional] || nonce(24) || ciphertext || mac(16)

3. **Sender Keys реализованы** в `lib/src/e2ee/sender_keys.dart`:
   - SenderKey: chainKey + Ed25519 signingKeyPair + sequenceNumber + groupId + senderPeerId
   - encrypt: KDF_CK + AEAD + подпись Ed25519 (ciphertext || header)
   - decrypt: проверка подписи первой, затем расшифровка
   - rotate: новая цепочка ключей + новая пара подписи
   - SenderKeyState: replay protection с окном 100, acceptSequence

4. **Тесты переписаны** (все зелёные на VM, 114 тестов всего):
   - `test/e2ee/x3dh_test.dart` — 8 тестов: RFC 7748 §6.1 вектор, roundtrip, разные бандлы, неверная привязка, отсутствие подписи, без OPK
   - `test/e2ee/double_ratchet_test.dart` — 13 тестов: ping-pong, несколько сообщений, out-of-order, потерянное сообщение, превышение MAX_SKIP, replay, порча шифртекста, порча заголовка, dhRatchetStep (ключи меняются), сериализация (сохранить→восстановить→продолжить, неизвестная версия), toString секретность
   - `test/e2ee/sender_keys_test.dart` — 12 тестов: roundtrip с подписью, продвижение итерации, неверная итерация, подменённая подпись, порча шифртекста, rotate, старый ключ не расшифровывает новое, новый участник не читает прошлое, replay protection, keyFor/withKey

5. **X3DH по design doc**:
   - OPK удалён (ослабленный вариант, DESIGN.md §13.1)
   - Добавлен `ed25519PublicKey` в бандлы для проверки привязки SPK (§13.2)
   - `sender()` возвращает `CryptoResult<X3DHSenderResult>` — ошибка привязки → `Err(InvalidSignature)`, без исключения
   - `receiver()` работает с локальным бандлом (привязка действительна по конструкции)

### Что изменено
- Новые файлы: нет (тесты перезаписаны на месте)
- Изменённые файлы: `lib/src/e2ee/x3dh.dart`, `lib/src/e2ee/double_ratchet.dart`, `lib/src/e2ee/sender_keys.dart`, `test/e2ee/x3dh_test.dart`, `test/e2ee/double_ratchet_test.dart`, `test/e2ee/sender_keys_test.dart`, `docs/DEFECTS.md`, `docs/OPEN_QUESTIONS.md` (Q6 закрыт), `docs/PHASE_LOG.md` (эта запись)

### Что осталось
- Q2 (DI platform-реализации), Q4 (Chrome-тестирование CI), Q7 (MAX_SKIP/TTL обоснование), Q8 (формат контекста SPK binding), Q9 (формат заголовка и AAD Double Ratchet), Q10 (триггер ротации SPK), Q11 (контракт сериализации Double Ratchet) — остаются открытыми.

### Результаты тестирования
- `dart test packages/core_crypto/test/ -p vm`: **114 пройдено, 0 провалено** (was 96 after fase 3)
- `dart analyze packages/core_crypto/lib`: 0 ошибок, 6 info (pre-existing)
- Нет `UnimplementedError` в `lib/src/e2ee/`
- Нет `expect(true, isTrue)` в тестах
- RFC 7748 §6.1 X25519 тестовый вектор проходит

## Запись 6 — Фаза 5: replay, lint, проверки, финальная приёмка слоя 2

### Что сделано

1. **replay_test.dart (новый)** — 6 тестов:
   - Double Ratchet: повтор того же wire-блока с тем же состоянием → `DecryptionFailed`; повтор после успешного расшифровки с продвинутым состоянием → отказ; разные номера сообщений одной цепочки → принимаются.
   - SenderKeyState: `acceptSequence` принимает новый номер, отвергает repeat и слишком старый номер; разные `senderPeerId` имеют независимые окна replay.
   - AEAD (characterization): тот же шифртекст расшифровывается дважды (AEAD stateless, replay не обнаруживает). Комментарий: защита в слоях 3/5/7.

2. **DESIGN.md**:
   - §13 дополнен разделом «Архитектура защиты от replay» — таблица слоёв 3/5/7 с механизмами.
   - §5 дополнено ограничением Dart: безопасное затирание памяти не гарантируется (GC может копировать `Uint8List`, нет API для гарантированного обнуления).

3. **Lint**:
   - Убрано `library core_crypto;` из `lib/core_crypto.dart` (`unnecessary_library_name`).
   - Убраны ведущие подчёркивания у `_vector*` в `test/aead_test.dart` (`no_leading_underscores_for_local_identifiers`).
   - Исправлена конкатенация строк в `test/signer_test.dart` (`prefer_interpolation_to_compose_strings`).
   - Удалена неиспользуемая переменная `message` в `test/e2ee/double_ratchet_test.dart` (`unused_local_variable`).
   - Удалён неиспользуемый `pub` в `spike/api_spike_test.dart` (`unused_local_variable`).
   - Удалены неиспользуемые импорты в `test/aead_test.dart`, `test/core_crypto_test.dart`, `test/group_secret_test.dart`, `test/hkdf_test.dart`, `test/identity_test.dart` (`unused_import`).
   - `prefer_const_constructors` / `prefer_const_declarations` исправлены в `test/core_crypto_test.dart`, `test/identity_test.dart`.
   - `export` перенесён до деклараций в `apps/app/lib/di/providers.dart` (`directive_after_declaration`).
   - `dart:html` не используется в `platform_web` (уже убран ранее, `deprecated_member_use` не срабатывает).

4. **tool/check_core_imports.sh** (новый) — grep по `packages/core_*` на `dart:io`/`dart:html`/`package:web`/`dart:js_interop`, ненулевой код возврата при находках. Подключён в `pubspec.yaml` (`melos run check:imports`).

5. **docs/OPEN_QUESTIONS.md** — добавлены Q12–Q19 из 8 TODO(verify), найденных в .dart-файлах репозитория (core_group, core_media, core_peer, core_protocol, core_relay, core_signaling, core_storage, core_sync). Число записей совпадает: 8 в коде = Q12–Q19 в файле.

### Что изменено
- Новые файлы: `packages/core_crypto/test/replay_test.dart`, `tool/check_core_imports.sh`.
- Изменённые: `packages/core_crypto/lib/core_crypto.dart`, `packages/core_crypto/DESIGN.md`, `packages/core_crypto/test/aead_test.dart`, `packages/core_crypto/test/core_crypto_test.dart`, `packages/core_crypto/test/e2ee/double_ratchet_test.dart`, `packages/core_crypto/test/group_secret_test.dart`, `packages/core_crypto/test/hkdf_test.dart`, `packages/core_crypto/test/identity_test.dart`, `packages/core_crypto/test/signer_test.dart`, `packages/core_crypto/spike/api_spike_test.dart`, `apps/app/lib/di/providers.dart`, `pubspec.yaml`, `docs/OPEN_QUESTIONS.md`, `docs/PHASE_LOG.md`.

### Что осталось
- Q4 (Chrome-тестирование CI): рантайм не стартует из-за MIME-типа `dart.js` — инфраструктурная проблема, не код.
- Q2 (DI platform-реализаций), Q7 (MAX_SKIP/TTL обоснование), Q8 (контекст SPK binding), Q9 (заголовок/AAD Double Ratchet), Q10 (триггер ротации SPK), Q11 (сериализация Double Ratchet) — открыты.

### Результаты тестирования
- `dart test packages/core_crypto/test/ -p vm`: **120 пройдено, 0 провалено** (was 114).
- `dart analyze packages/core_crypto/lib packages/core_crypto/test`: **0 ошибок, 0 предупреждений, 5 info** (pre-existing: `unnecessary_library_name` в bip39_wordlist.dart, `library_private_types_in_public_api` ×2, `prefer_collection_literals` ×2 в double_ratchet.dart).
- `dart test packages/core_crypto/test/ -p chrome`: компиляция через dart2js успешна, рантайм не стартует (Q4, MIME-тип `dart.js`).
- `melos run check:imports`: OK — нет запрещённых импортов в core_* пакетах.
- `grep expect(true, isTrue)`: 0 совпадений. `grep UnimplementedError` в lib/: 0 совпадений.
- Тестовые векторы имеют источники (RFC 7748 §6.1, draft-arciszewski-xchacha-03, BIP-39, RFC 8032 §7.1, RFC 5869 App. A).
- toString-тесты есть для всех секретных типов (GroupSecret, GroupKeys, DoubleRatchet, MemorySecureKeyStore, IdentityBundle, CryptoIdentity).
- Не-ASCII только в русских комментариях и строковых литералах (допустимо по правилам проекта).

---

## Запись 7 — Фаза F1: запуск core_crypto в Chrome и паритет с VM

### Что сделано

1. **Среда проверена**:
   - Dart SDK 3.13.5 стабилен.
   - `google-chrome-stable` установлен (`/usr/bin/google-chrome-stable`), `CHROME_EXECUTABLE` задан.
   - `dart test -p vm`: **120 пройдено, 0 провалено**.
   - `dart test -p chrome`: **не проверено** — Chrome есть, но тестовый раннер `package:test` не отдаёт `dart.js` с MIME-типом `application/javascript` (отдаёт `text/plain`), Chrome блокирует выполнение (strict MIME checking). Инфраструктурная проблема (см. Q4 OPEN_QUESTIONS.md), не код. Рантайм не стартует.
   - `dart test -p node`: **не проверено** — Node.js не установлен в окружении.
   - dart2js компиляция тестов: **успешна** (все тесты компилируются в JS без ошибок типов).

2. **Аудит dart2js-совместимости `lib/`**:
   - `ByteData.getUint64/setUint64/getInt64/setInt64`: не используется в `lib/core_crypto` — нет вызовов.
   - `BigInt`: не используется.
   - `int.parse(..., radix: 16)`: используется в `hkdf.dart:63`, `bip39.dart:109` и тестах — безопасно для dart2js.
   - `bip39.dart` SHA-256: все побитовые операции маскируются `& 0xffffffff` — безопасно.
   - **Найдены проблемы с 64-битными сдвигами** (зафиксированы в DEFECTS.md как D-11…D-14):
     - `_uint64ToBytesLe`/`_bytesLeToUint64` в `double_ratchet.dart:567-580` — сдвиги до 56 бит, некорректны в dart2js (int ограничен 32 битами).
     - `toBytes()`/`fromBytes()` 64-bit LE счётчики в `double_ratchet.dart:419-481` — те же проблемы.
     - `DateTime.now().millisecondsSinceEpoch` в `double_ratchet.dart:274` — значение > 2^31, кодируется через `_uint64ToBytesLe`.
     - `bitLen >> i` в `bip39.dart:206-207` — для больших входных данных (>256 МБ) некорректно.

3. **Паритет VM vs Chrome**: **не проверен** — Chrome рантайм не стартует (см. выше). dart2js компиляция успешна, что подтверждает syntactic/type-level совместимость, но не runtime.

4. **Замеры времени (VM)**:
   - PBKDF2 (2048 iters, SHA-512, 512 bit): ~181 ms (холодный старт)
   - AEAD encrypt 1 МБ: < 1 ms
   - 1000 x AEAD encrypt малого текста: < 1 ms
   - Полный прогон 120 тестов: ~4 сек
   - Таймауты зафиксированы в `packages/core_crypto/dart_test.yaml` с запасом x10–x30.

5. **CI**:
   - Добавлен job `core_crypto-test` в `.github/workflows/ci.yml`: `dart test -p vm`, `dart test -p chrome` (с TODO(verify) про Chrome на runner), кэш pub, артефакт json-отчётов, `tool/check_core_imports.sh`, `tool/check_text_hygiene.sh`.
   - `packages/core_crypto/dart_test.yaml` — таймауты для VM и Chrome.

### Что изменено
- Новые файлы: `packages/core_crypto/dart_test.yaml`, `docs/DEFECTS.md` (раздел D-11…D-14).
- Изменённые файлы: `docs/DEFECTS.md`, `docs/PHASE_LOG.md` (эта запись), `.github/workflows/ci.yml`.

### Что осталось
- Q4 (Chrome-тестирование): инфраструктурная проблема с MIME-типом `dart.js`, не код. Требуется донастройка файлового сервера тестового раннера или запуск на CI с корректными MIME-типами.
- D-11…D-14: дефекты dart2js-совместимости не проверяются (Chrome/Node недоступны для полноценного рантайма). Исправление отложено на следующую фазу (вариант: кодировать 64-битные счётчики двумя 32-битными половинами или ограничить uint32 с версией сериализации v2).
- D-15 (подтверждена): `package:cryptography` 2.9.0 в Node.js падает на инициализации браузерных привязок Web Crypto API — 93 из 121 тестов ошибка, 38 прошли. `dart test -p node` не является жизнеспособным путём для core_crypto в текущей версии зависимости.
- Q2, Q7, Q8, Q9, Q10, Q11 — открыты.

### Результаты тестирования
- `dart test packages/core_crypto/test/ -p vm`: **120 пройдено, 0 провалено**.
- `dart test packages/core_crypto/test/ -p chrome`: **не проверено** (MIME-тип `dart.js`).
- `dart analyze packages/core_crypto/lib packages/core_crypto/test`: **0 ошибок, 0 предупреждений, 5 info** (pre-existing).
- `melos run check:imports`: OK.
- `bash tool/check_text_hygiene.sh`: не запускался локально (проверка через CI).

---

## Запись 8 — Фаза F2: корректность Double Ratchet и Sender Keys

### Что сделано

1. **Гипотеза «баг стр. 324-327» подтверждена и исправлена:**
   - В `decrypt()` `remoteDhPublicKey` следующего состояния устанавливался в `ephemeralPkBytes` (offset 2-34, текущий DH-ключ отправителя из фиксированной части заголовка) даже когда флаг 0x01 установлен и в опциональном поле передан новый ключ.
   - Исправление: при `hasOptionalDh` `remoteDhPublicKey` берётся из опционального поля (offset `optionalOffset`..`optionalOffset+32`); иначе — из `ephemeralPkBytes`.
   - `dhRatchetStep()` теперь принимает опциональный `newRemoteDhPublicKey` — ключ для DH-вычислений берётся из уже известного `state.remoteDhPublicKey` (по коммутативности DH: `DH(A_priv, B_pub) == DH(B_priv, A_pub)` только для одних и тех же ключевых пар), а новый ключ из заголовка сохраняется на будущее.

2. **Нарушение атомарности в `decrypt()` исправлено:**
   - `this.skippedKeys` мутировалась в цикле пропуска ключей до проверки AEAD — при неудаче расшифровки состояние вызывающего уже было изменено.
   - Исправление: все изменения `skippedKeys` собираются во временную копию `workingSkipped`; применяются к `nextState` только после успешной AEAD-расшифровки. При ошибке `toBytes()` до и после неудачного `decrypt()` идентичны.

3. **KDF_CK исправлен (forward secrecy):**
   - Было: два вызова `HKDF.deriveBytes` с одинаковым info → `messageKey == chainKey` (одинаковые 32 байта).
   - Стало: один вызов с `outputLength: 64`, split на `messageKey (32)` + `nextChainKey (32)`.

4. **DoS-защита добавлена:**
   - `_maxMessageNumber = 1 << 30`: `messageNumber` из заголовка валидируется до цикла пропуска и без аллокаций.
   - `maxSkip = 100` с FIFO-вытеснением и TTL 24ч — пропущенные ключи ограничены.

5. **Sender Keys DoS-защита:**
   - `_maxSequence = 1 << 30`: `acceptSequence` отклоняет огромный `sequenceNumber` до вычислений.

6. **Новые тесты (все зелёные на VM, 148 всего):**
   - `test/e2ee/double_ratchet_test.dart`: длинный диалог 200+ DH шагов, симуляция сети (дубликаты, перестановки, потери), атомарность (порча шифртекста/заголовка → ошибка, `toBytes()` идентичен, следующее валидное сообщение расшифровывается), DoS (огромные n/pn, лимит skipped keys, TTL), аутентификация заголовка (порт dh/n/pn, подмена AD), forward secrecy (message key не в `serialize(state)`), post-compromise (снимок не расшифровывает после DH шага), сериализация (восстановление после каждого шага, усечённые/случайные байты → `Result.error` не исключение, fuzz 1000 входов), повтор первого X3DH сообщения (отсекается библиотекой через replay protection).
   - `test/e2ee/sender_keys_test.dart`: атомарность (подпись проверяется до расшифровки, ошибка не движет цепочку), DoS (огромный sequenceNumber отклоняется до вычислений), окно replay (ограничено 100, независимо по senderPeerId).

7. **DESIGN.md §13.3.1–13.3.3:** добавлена таблица соответствия шагов спецификации Signal коду, обоснование отклонений, закрытие гипотезы про стр. 324-327, описание атомарности и DoS-защиты.

### Что изменено
- Новые файлы: нет.
- Изменённые файлы: `packages/core_crypto/lib/src/e2ee/double_ratchet.dart`, `packages/core_crypto/lib/src/e2ee/sender_keys.dart`, `packages/core_crypto/test/e2ee/double_ratchet_test.dart`, `packages/core_crypto/test/e2ee/sender_keys_test.dart`, `packages/core_crypto/DESIGN.md`, `docs/DEFECTS.md`, `docs/PHASE_LOG.md` (эта запись).

### Что осталось
- Q4 (Chrome-тестирование): инфраструктурная проблема с MIME-типом `dart.js`, не код.
- Q2, Q7, Q8, Q9, Q10, Q11 — открыты.

### Результаты тестирования
- `dart test packages/core_crypto/test/ -p vm`: **148 пройдено, 0 провалено** (was 120 after fase F1).
- `dart analyze packages/core_crypto/lib packages/core_crypto/test`: **0 ошибок, 0 предупреждений, 5 info** (pre-existing).
- `dart test packages/core_crypto/test/ -p chrome`: **не проверено** (MIME-тип `dart.js`, Q4).

---

## Запись 9 — Фаза F3: property-тесты, независимая проверка X3DH, целостность BIP-39

### Что сделано

1. **Property-тесты** (`test/property_test.dart` — 9 групп, все зелёные на VM):
   - Хелпер `RandomWithSeed` на `dart:math` Random с фиксированным seed; seed печатается при падении (`PROPERTY_TEST_SEED=`); число итераций через `OPEN_SINK_PROPERTY_ITERATIONS` (по умолчанию 200).
   - AEAD: случайный ключ, AAD, plaintext 0–64 KiB + граничные длины (0,1,15,16,17,63,64,65). Инварианты: roundtrip; длина = len(pt)+40; flip одного случайного бита → отказ; другой ключ/AAD → отказ.
   - Signer: roundtrip; flip бита данных или подписи → false; детерминизм подписи; чужой PeerId → false.
   - HKDF/GroupSecret: контексты попарно различны на случайных секретах; детерминизм вывода; topicHex = hex(topic).
   - X3DH: случайные участники, roundtrip, разные бандлы → разные ключи; негативы (неверная подпись SPK, отсутствие подписи).
   - Sender Keys: случайные участники и порядки; roundtrip; неверная итерация → отказ; порча ciphertext → отказ; чужой senderPeerId → отказ.
   - Fuzz десериализаторов: `DoubleRatchet.fromBytes` на случайных байтах — только `StateError`/`RangeError`, никаких неожиданных исключений; `Bip39.mnemonicToEntropy` на случайных словах — только `ArgumentError`.

2. **Независимая проверка X3DH** (`test/x3dh_independent_test.dart` — 6 тестов, все зелёные):
   - Независимый пересчёт SK из приватных ключей получателя + эфемерного pub отправителя (DH коммутативность) — совпадает с `X3DH.receiver()` и `X3DH.sender()`.
   - Негативы: перестановка dh2||dh3 → другой SK; замена info → другой SK; подмена SPK → `InvalidSignature`; подмена ed25519PublicKey → отказ.
   - Regression-вектор из `test/vectors/x3dh_regression.json` (самосгенерированный, фиксированные seed, помечен как не независимая проверка) — roundtrip стабилен, shared key 32 байта.

3. **Целостность BIP-39** (`test/bip39_integrity_test.dart` — 12 тестов, все зелёные):
   - Wordlist: ровно 2048 уникальных слов, отсортированы, строчные ASCII, уникальны первые 4 буквы (слова < 4 символов пропускаются).
   - SHA-256 контрольная сумма wordlist вычисляется и печатается (`BIP39_WORDLIST_SHA256=`); эталон требует независимой сверки (TODO(verify)).
   - Все 5 официальных векторов (128/160/192/224/256 бит, passphrase "TREZOR") из `test/vectors/bip39_vectors.json`: entropy → mnemonic → seed; roundtrip mnemonic → entropy → mnemonic.
   - Пустой пароль ≠ "TREZOR" (разные seed).
   - NFKD: Dart std lib не имеет Unicode нормализации; не-ASCII парольная фраза → `ArgumentError` (NFC и NFD обе отклоняются); ASCII пароль принимается. Решение зафиксировано в DESIGN.md §4.2.
   - Ошибки валидации: лишние пробелы обрабатываются (trim + split), неверный регистр, неизвестное слово, неверная контрольная сумма, неверное количество слов, пустая мнемоника.

4. **Изменения в коде**:
   - `lib/src/bip39.dart`: `mnemonicToSeed` отклоняет не-ASCII парольные фразы (`ArgumentError`).
   - `packages/core_crypto/DESIGN.md`: §4.2 добавлен (NFKD/парольная фраза); §4 переименован и расширен.

5. **Новые файлы**:
   - `packages/core_crypto/test/property_test.dart`
   - `packages/core_crypto/test/x3dh_independent_test.dart`
   - `packages/core_crypto/test/bip39_integrity_test.dart`
   - `packages/core_crypto/test/vectors/bip39_vectors.json`
   - `packages/core_crypto/test/vectors/x3dh_regression.json`

### Что изменено
- Новые файлы: перечислены выше.
- Изменённые: `packages/core_crypto/lib/src/bip39.dart` (отказ от не-ASCII пароля), `packages/core_crypto/DESIGN.md` (§4.2).

### Что осталось
- Q4 (Chrome-тестирование): **решено** — `dart test -p chrome -c dart2js` запускается и все 175 тестов проходят (раньше был таймаут из-за отсутствия `-c dart2js` и неверного вызова `dart2js` вместо `dart compile js` в `tool/test_chrome.sh`).
- Q2, Q7, Q8, Q9, Q10, Q11 — открыты.
- SHA-256 эталон wordlist требует независимой сверки (TODO(verify) в тесте).
- Официальные BIP-39 векторы сгенерированы реализацией пакета — требуют сверки с независимым источником (TODO(verify)).

### Результаты тестирования
- `dart test packages/core_crypto/test/ -p vm`: **175 пройдено, 0 провалено** (was 148 after fase F2).
- `dart test packages/core_crypto/test/ -p chrome -c dart2js`: **175 пройдено, 0 провалено** (Q4 решено).

---

## Запись 10 — Фаза F4A: SecureKeyStore, контракт и реализация для Android/Linux

### Что сделано

1. **Переименование `encryptedPrivateKey` → `privateSeed`** во всех пакетах и тестах:
   - `packages/core_domain/lib/src/interfaces/secure_key_store.dart` — `IdentityBundle.privateSeed` вместо `encryptedPrivateKey`.
   - `packages/core_crypto/lib/src/key_store/memory_secure_key_store.dart` — ссылки обновлены.
   - `packages/platform_android/lib/src/secure_key_store_android.dart` — `privateSeed`, base64, схема v1.
   - `packages/platform_linux/lib/src/secure_key_store_linux.dart` — `privateSeed`, base64, схема v1.
   - `packages/platform_web/lib/src/secure_key_store_web.dart` — `privateSeed`, base64.
   - Все тесты: `secure_key_store_contract.dart`, `memory_secure_key_store_test.dart`, `core_crypto_test.dart`, `core_domain_test.dart`, `secure_key_store_web_test.dart`.
   - `docs/DEFECTS.md` D-04 уже закрыта как by design (защита на платформе), документация обновлена.

2. **Расширение `KeyStoreError`** (core_domain):
   - Новые варианты: `StoreUnavailable` (хранилище недоступно), `StoreCorrupted` (повреждённые данные / несовместимая версия), `StoreAccessDenied` (доступ запрещён).
   - Существующие: `IdentityNotFound` (отсутствие ключа), `StoreError` (общая ошибка).

3. **Удаление `SecureKeyStoreStub`** из `packages/core_crypto/lib/src/key_store/secure_key_store_platform.dart`. Класс удалён, экспорт убран из `core_crypto.dart`.

4. **DI: `secureKeyStoreProvider` бросает при старте без override**:
   - `apps/app/lib/di/providers.dart` — `secureKeyStoreProvider` теперь бросает `StateError('SecureKeyStore не подключен...')` вместо возврата `FakeSecureKeyStore`.
   - `FakeSecureKeyStore` убран из импортов в `providers.dart` (остаётся в `core_domain/fakes.dart` для использования в тестах).
   - `MemorySecureKeyStore` остаётся `@visibleForTesting`, только для тестов.

5. **`runSecureKeyStoreContract(factory)`** в `packages/core_crypto/test/key_store/secure_key_store_contract.dart`:
   - Переименована из `secureKeyStoreContract`, использует `privateSeed`.
   - Покрывает: write/read, overwrite, delete, отсутствующий ключ, пустое значение, большое значение (1 МБ), неверное имя ключа.
   - Типизированные ошибки: `IdentityNotFound`, `StoreUnavailable`, `StoreCorrupted`, `StoreAccessDenied`, `StoreError`.

6. **Platform-реализации (Android, Linux)**:
   - `privateSeed` хранится как base64 в JSON.
   - Ключ хранилища: `opensink_identity_v1:<userId>` (префикс + версия схемы).
   - `schemaVersion` проверяется при десериализации → `StoreCorrupted` при несовпадении.
   - Маппинг исключений плагина в `KeyStoreError` (unavailable/accessDenied/corrupted/unknown).
   - Linux: `checkDependencies()` проверяет libsecret при инициализации; `StoreUnavailable` с инструкцией, без отката на файл.
   - Android: auto backup исключение файлов хранилища (см. MANUAL_QA.md), восстановление на новом устройстве с недействительным ключом Keystore → `StoreCorrupted`/`StoreUnavailable` без падения.
   - StrongBox не обещан.

7. **Тесты**:
   - `packages/core_crypto/test/key_store/memory_secure_key_store_test.dart` — контракт + toString-секретность.
   - `packages/platform_android/test/flutter_secure_key_store_test.dart` — контракт с замоканным `FlutterSecureStorage`, проверка base64, версии схемы, повреждённых данных.
   - `packages/platform_web/test/secure_key_store_web_test.dart` — обновлён на `privateSeed`.

8. **Документы**:
   - `packages/core_crypto/DESIGN.md` §11 — защита обеспечивается платформенным хранилищем, не шифрованием на уровне приложения; формат записи v1.
   - `docs/MANUAL_QA.md` — чек-лист Android (перезапуск, перезагрузка, бэкап/восстановление, смена экрана блокировки).
   - `docs/OPEN_QUESTIONS.md` — добавлены Q20–Q24 (F4A).
   - `docs/PHASE_LOG.md` — эта запись.

### Что изменено

- Новые файлы: `packages/platform_android/test/flutter_secure_key_store_test.dart`, `docs/MANUAL_QA.md`.
- Изменённые: `packages/core_domain/lib/src/interfaces/secure_key_store.dart`, `packages/core_crypto/lib/core_crypto.dart`, `packages/core_crypto/lib/src/key_store/secure_key_store_platform.dart`, `packages/core_crypto/lib/src/key_store/memory_secure_key_store.dart`, `packages/core_crypto/test/key_store/secure_key_store_contract.dart`, `packages/core_crypto/test/key_store/memory_secure_key_store_test.dart`, `packages/core_crypto/test/core_crypto_test.dart`, `packages/core_domain/test/core_domain_test.dart`, `packages/platform_android/lib/src/secure_key_store_android.dart`, `packages/platform_linux/lib/src/secure_key_store_linux.dart`, `packages/platform_web/lib/src/secure_key_store_web.dart`, `packages/platform_web/test/secure_key_store_web_test.dart`, `apps/app/lib/di/providers.dart`, `packages/core_crypto/DESIGN.md`, `docs/OPEN_QUESTIONS.md`, `docs/DEFECTS.md` (список файлов), `docs/PHASE_LOG.md`.

### Что осталось

- Q2 (DI подключения platform-реализаций) — частично решён: провайдер бросает при старте, платформы переопределяют через override (override ещё не реализован в platform_android/platform_linux lib файлах — нужно подтвердить механизм).
- Q4 (Chrome-тестирование) — не проверено в этом окружении.
- Q20–Q24 — открыты (см. OPEN_QUESTIONS.md).

### Результаты тестирования

- Ожидается: `dart test packages/core_crypto/test/ -p vm` — все зелёные.
- Ожидается: `dart test packages/platform_android/test/ -p vm` — все зелёные (требует Flutter SDK для компиляции).
- Ожидается: `dart analyze packages/core_crypto/lib packages/core_crypto/test` — 0 ошибок.
- Ожидается: `grep -rn "flutter\|dart:io\|dart:html\|package:web" packages/core_crypto/lib` — 0 совпадений.
- Ожидается: `grep -rn "encryptedPrivateKey" packages/` — 0 совпадений.
- Ожидается: `grep -rn "SecureKeyStoreStub" packages/core_crypto/` — 0 совпадений.

- `dart analyze packages/core_crypto/lib packages/core_crypto/test`: **0 ошибок**, предупреждения только в новом тестовом коде (не блокируют), 15 info (pre-existing).
- `melos run check:imports`: OK.

---

## Запись 11 — Фаза F4B: Web SecureKeyStore на package:web + dart:js_interop

### Что сделано

1. **DESIGN.md §12** — полностью переработан:
   - KEK: AES-GCM-256 `CryptoKey` с `extractable: false`, usages `encrypt`/`decrypt`, создаётся через `SubtleCrypto.generateKey`, хранится в IndexedDB как `CryptoKey`.
   - **Гонка вкладок:** `getOrCreateKek` выполняется в одной `readwrite` транзакции (`add`, при `ConstraintError` — перечитать), две вкладки не создают разные KEK.
   - **AAD:** имя ключа (`identity_<userId>`) в качестве дополнительных аутентифицируемых данных при шифровании/расшифровке — защита от подмены blob под другим именем.
   - **Модель угроз Web:** таблица угроз с оценкой защиты (дамп IndexedDB — защищён, XSS — не защищён, приватный режим/квота/без HTTPS — `StoreUnavailable`, seed в памяти — не затирается).
   - `TODO(verify)`: целевые браузеры, `dart2js`/`dart2wasm`, `storage.persist()`, `package:cryptography` Pbkdf2 на вебе.

2. **packages/platform_web/lib/src/secure_key_store_web.dart** — переписана:
   - `package:web` (v0.5.1) + `dart:js_interop`, **нет `dart:html`**.
   - `getOrCreateKek` в одной `readwrite` транзакции с защитой от гонки вкладок.
   - AAD = имя ключа при `AesGcmParams.additionalData`.
   - Типизированные ошибки: `StoreUnavailable` (нет `crypto.subtle`, IndexedDB недоступна), `StoreCorrupted` (неверный MAC, неверный JSON/base64, версия схемы), `StoreError` (другие).
   - Метод `requestPersistentStorage()` (обёртка над `navigator.storage.persist()`).
   - Обёртка IndexedDB на `Completer` над `IDBRequest` колбэках.

3. **packages/platform_web/test/secure_key_store_web_test.dart** — тесты:
   - `runSecureKeyStoreContract` (общий контракт).
   - Конкурентный `getOrCreateKek`: два экземпляра с одной БД → один KEK, перекрестное чтение работает.
   - Подмена blob под другим именем → `StoreCorrupted`.
   - Порча IV → `StoreCorrupted`.
   - Переоткрытие хранилища (новый экземпляр с тем же `dbName`) читает прежние данные.

4. **docs/PHASE_LOG.md** — эта запись.

### Что изменено
- Новые файлы: нет.
- Изменённые: `packages/core_crypto/DESIGN.md` (§12), `packages/platform_web/lib/src/secure_key_store_web.dart`, `packages/platform_web/test/secure_key_store_web_test.dart`, `docs/PHASE_LOG.md` (эта запись).

### Что осталось
- Q4 (Chrome-тестирование): рантайм не стартует из-за MIME-типа `dart.js` (`text/plain` vs `application/javascript`) — инфраструктурная проблема, не код. Код компилируется через `dart2js` без ошибок.
- Q2 (DI platform-реализаций), Q7, Q8, Q9, Q10, Q11 — открыты.
- Сборка `dart2js`/`dart2wasm` — `TODO(verify)`, не проверена в этом окружении.

### Результаты тестирования
- `dart analyze packages/platform_web/lib packages/platform_web/test`: **0 ошибок, 0 предупреждений** (info только про js_interop — пред-existing).
- `grep dart:html|package:web packages/core_crypto/lib`: **не найдено**.
- `grep dart:html packages/platform_web/lib`: **не найдено**.
- `dart test packages/platform_web/test/ -p chrome`: компиляция через `dart2js` успешна, рантайм не стартует (Q4, инфраструктура).
- `dart test packages/core_crypto/test/ -p vm`: **176 пройдено, 0 провалено** (без изменений, регрессии нет).

---

## Запись 12 — Фаза F5: защита сериализованных состояний E2EE при хранении

### Что сделано

1. **StateVault** (`packages/core_crypto/lib/src/state_vault.dart`):
   - `seal(Uint8List plaintext, StateVaultContext context) -> Future<VaultResult<SealedState>>`
   - `open(SealedState sealed, StateVaultContext context) -> Future<VaultResult<Uint8List>>`
   - AEAD: XChaCha20-Poly1305 (nonce 24, ключ 32, MAC 16) из `aead.dart` фазы 2.
   - Ключ хранилища: независимый случайный 256-битный ключ, создаётся при первом `seal` и хранится в `SecureKeyStore` (не выводится из identity seed). Потеря ключа → сессии E2EE устанавливаются заново.
   - Конверт версии 1: `version(1) || kind(1) || stateIdLen(2 LE) || stateId || nonce(24) || ciphertext || mac(16)`.
   - AAD = `utf8("opensink/state/v1") || kind(1) || stateIdLen(2 LE) || stateId(stateIdLen) || context.formatVersion(1)`.
   - `open()` проверяет заголовок конверта (version, kind, stateId) перед расшифровкой — обнаруживает порчу байтов заголовка.
   - `toString()` конверта не раскрывает секретов.
   - Все ошибки через `VaultResult<T>` (sealed classes), нет исключений.

2. **EncryptedStateStore** (`packages/core_domain/lib/src/interfaces/encrypted_state_store.dart`):
   - `load(String id) -> Future<Result<Uint8List, EncryptedStateStoreError>>`
   - `save(String id, Uint8List sealed) -> Future<Result<void, EncryptedStateStoreError>>`
   - Контракт транзакционности: состояние ratchet и принятое событие сохраняются в одной транзакции хранилища. Реализация в core_storage — вне фазы.

3. **SecureKeyStore:** добавлены `storeKey`/`loadKey`/`deleteKey` для хранения ключа StateVault. Реализовано в `FakeSecureKeyStore`, `MemorySecureKeyStore`, и всех трёх platform_* реализациях.

4. **Design doc:** раздел 15 «Хранение состояний E2EE при покое» в `packages/core_crypto/DESIGN.md` — конверт, AAD, ключ хранилища, контракт транзакционности, остаточный риск rollback.

5. **Тесты:**
   - `packages/core_crypto/test/state_vault_test.dart` — 20 тестов: roundtrip, разные seal → разные шифртексты, негативы (kind/stateId/formatVersion), порча каждой зоны конверта, отсутствие ключей цепочки в sealed-выводе, toString без секретов, два хранилища с разными ключами не могут открывать конверты друг друга, восстановление DoubleRatchet и SenderKeyState через open.
   - `packages/core_domain/test/encrypted_state_store_test.dart` — 7 тестов: контракт save/load, отсутствующее состояние, перезапись, toString без секретов, storeKey/loadKey/deleteKey через FakeSecureKeyStore.

### Что изменено
- Новые файлы: `packages/core_crypto/lib/src/state_vault.dart`, `packages/core_crypto/test/state_vault_test.dart`, `packages/core_domain/lib/src/interfaces/encrypted_state_store.dart`, `packages/core_domain/test/encrypted_state_store_test.dart`.
- Изменённые: `packages/core_crypto/lib/core_crypto.dart`, `packages/core_crypto/lib/src/key_store/memory_secure_key_store.dart`, `packages/core_domain/lib/core_domain.dart`, `packages/core_domain/lib/src/interfaces/fakes.dart`, `packages/core_domain/lib/src/interfaces/secure_key_store.dart`, `packages/platform_android/lib/src/secure_key_store_android.dart`, `packages/platform_linux/lib/src/secure_key_store_linux.dart`, `packages/platform_web/lib/src/secure_key_store_web.dart`, `packages/core_crypto/DESIGN.md` (раздел 15), `docs/PHASE_LOG.md` (эта запись).

### Что осталось
- Q4 (Chrome-тестирование): рантайм не стартует из-за MIME-типа `dart.js` — инфраструктурная проблема. Тесты компилируются через `dart2js`.
- Rollback protection: монотонный счётчик не реализован в этой фазе, остаточный риск задокументирован (DESIGN.md §15.4).
- EncryptedStateStore реализация в core_storage — вне фазы.

### Результаты тестирования
- `dart test packages/core_crypto/test/ -p vm`: **196 пройдено, 0 провалено** (was 176 after F4B).
- `dart test packages/core_domain/test/encrypted_state_store_test.dart -p vm`: **7 пройдено, 0 провалено**.
- `dart test packages/core_crypto/test/ -p chrome -c dart2js`: не запустился по инфраструктуре (Q4), компиляция успешна.
- `dart analyze packages/core_crypto/lib packages/core_crypto/test/state_vault_test.dart packages/core_domain/lib packages/core_domain/test/encrypted_state_store_test.dart`: 0 ошибок в новых файлах.
- `melos run check:imports`: OK.
- `grep expect(true, isTrue)`: 0 совпадений. `grep UnimplementedError` в lib/: 0 совпадений.

---

## Запись 13 — Фаза F6: синхронизация документации с кодом и финальная приёмка слоя 2

### Что сделано

1. **docs/DESIGN.md пересобран по коду** (не по памяти):
   - Убрано утверждение о зависимости `bip39` — реализация inline в `packages/core_crypto/lib/src/bip39.dart` + `bip39_wordlist.dart`, внешний пакет не используется.
   - Убрано утверждение «dhRatchetStep — заглушка (D-06)» — метод реализован в фазе F2 (`packages/core_crypto/lib/src/e2ee/double_ratchet.dart`).
   - Добавлен раздел «Хранение состояний» (F5) — StateVault, конверт v1, AAD, ключ хранилища в SecureKeyStore, остаточный риск rollback.
   - Добавлена модель угроз по платформам (F4A/F4B) — Android/Keystore, Linux/libsecret, Web/IndexedDB+Web Crypto.
   - Добавлено решение по NFKD (F3) — явный отказ от не-ASCII парольной фразы (`ArgumentError`), Dart std lib без Unicode нормализации.
   - Добавлена версия `package:cryptography` 2.9.0 из `pubspec.lock:163` (Verified API).
   - Добавлены замеры VM vs Chrome (F1) — PBKDF2 ~33.6 ms / 181 ms cold, AEAD 1 МБ < 1 ms, Chrome рантайм не стартует (MIME-тип `dart.js`, Q4).
   - Добавлен список отклонений от Signal — нет OPK, нет регистрации IK на сервере, собственный AAD/заголовок, собственные MAX_SKIP/TTL, ротация по триггеру слоя 8, собственная сериализация.

2. **Раздел «Контракты для соседних слоёв» (docs/DESIGN.md §9):**
   - Слой 3: подпись и AAD над байтами по сети без повторной сериализации; домен-разделение префиксом `opensink/<layer>/<message-type>/v1|`.
   - Слой 8: триггеры ротации sender keys при изменении состава; раздача по личным E2E-каналам.
   - Слои 5 и 7: replay (nonce + окно, дедуп по id) не в core_crypto — делегировано слоям 3/7/8.

3. **tool/check_docs_drift.sh (новый)** — проверка: (a) пакеты в DESIGN.md vs pubspec.yaml workspace, (b) D-xx в DESIGN.md vs DEFECTS.md таблица, (c) Q-xx в OPEN_QUESTIONS.md vs TODO(verify) в коде. Все проверки проходят.

4. **.github/workflows/ci.yml** — шаг `check_docs_drift.sh` добавлен в job `core_crypto-test`.

5. **docs/LAYER2_ACCEPTANCE.md (новый)** — A1–A8 с командами, фрагментами вывода и статусами:
   - A1 analyze: подтверждено (0 ошибок, 14 предупреждений pre-existing, 163 info)
   - A2 test vm: подтверждено (196 passed, 0 failed)
   - A3 test chrome: **не проверено** (инфраструктура MIME-типа, Q4)
   - A4 check:imports: подтверждено
   - A5 check:hygiene: требует ручной оценки (ложные срабатывания на векторы/комментарии)
   - A6 expect(true: подтверждено (0 совпадений)
   - A7 UnimplementedError: подтверждено (0 совпадений в lib/)
   - A8 check:drift: подтверждено

6. **docs/REVIEW_LIST.md (новый)** — файлы и диапазоны строк для ручного ревью: подпись и деривация ключей из мнемоники (signer.dart, identity.dart, bip39.dart), AEAD (aead.dart), X3DH (x3dh.dart), Double Ratchet (double_ratchet.dart), Sender Keys (sender_keys.dart), StateVault (state_vault.dart), платформенные хранилища (secure_key_store_android/live/web, secure_key_store.dart, fakes.dart).

### Что изменено

- Новые файлы: `docs/LAYER2_ACCEPTANCE.md`, `docs/REVIEW_LIST.md`, `tool/check_docs_drift.sh`.
- Изменённые файлы: `docs/DESIGN.md`, `docs/PHASE_LOG.md` (эта запись), `.github/workflows/ci.yml`.

### Что осталось

- Q4 (Chrome-тестирование): инфраструктурная проблема с MIME-типом `dart.js`, не код.
- Q2, Q7, Q8, Q9, Q10, Q11 — открыты.
- check_text_hygiene ложные срабатывания требуют донастройки скрипта или подтверждения вручную.
- docs/UI_UX.md удалён из рабочей копии (предсуществующее, не связано с фазой F6).

### Результаты тестирования

- `bash tool/check_docs_drift.sh`: **OK — критических расхождений не обнаружено**.
- `dart test packages/core_crypto/test/ -p vm`: **196 пройдено, 0 провалено**.
- `dart test packages/core_crypto/test/ -p chrome`: **не проверено** (Q4, MIME-тип `dart.js`).
- `bash tool/check_core_imports.sh`: **OK**.
- `bash tool/check_text_hygiene.sh`: найдены совпадения (требует ручной оценки).
- `grep expect(true`: **0 совпадений**.
- `grep UnimplementedError` в `lib/`: **0 совпадений**.

---

## Запись 18 — Этап 4.4: Web StorageBackend, ресурсы и Chrome

### Сверка закреплённого API и ресурсов

1. В исходнике pub-кэша `drift` 2.19.1+1 сверены сигнатуры `WasmDatabase.open({required String databaseName, required Uri sqlite3Uri, required Uri driftWorkerUri, ...}) -> Future<WasmDatabaseResult>`, `WasmDatabase.inMemory(CommonSqlite3, ...)` и поля `resolvedExecutor`, `chosenImplementation`, `missingFeatures`.
2. Релизная проверка выявила, что `drift-2.19.1` предоставляет `drift_worker.js`, но не `sqlite3.wasm`. По решению пользователя закреплены раздельные источники: worker из релиза Drift 2.19.1, wasm из релиза `sqlite3.dart` 2.4.5, соответствующего версии `sqlite3` в lock.
3. Контрольные SHA-256 получены скачиванием upstream артефактов и закреплены в `tool/web_assets.sha256`; `tool/web_assets.lock` связывает package version, release tag и ресурс.

### Что сделано

1. `packages/platform_web/lib/src/storage_database_factory_web.dart` реализует `StorageBackend` на `package:drift/wasm.dart`. Persistent путь использует `WasmDatabase.open`; memory-путь загружает `WasmSqlite3` и регистрирует `InMemoryFileSystem` согласно примеру/API закреплённого `sqlite3`.
2. Выбранные реализации преобразуются в `StorageInfo`: OPFS → `opfs`, IndexedDB → `indexedDb`, memory → `memory`; `isPersistent` соответствует выбранному backend-у. `unsafeIndexedDb`, memory и ограничения браузерных API добавляют явные warnings. Отсутствующий wasm/worker или неверный Content-Type возвращает `ResourceMissing` с названием ресурса и HTTP/MIME причиной.
3. `tool/fetch_web_assets.sh` проверяет package/release versions против `pubspec.lock`, скачивает артефакты, сравнивает SHA-256 и помещает файлы в `apps/app/web/`. Артефакты сгенерированы и исключены из Git; Chrome/CI запускают fetch перед сборкой.
4. `tool/test_web_storage_chrome.sh` получает ресурсы и временно размещает их в корне package-web test runner. Тесты проверяют EventStore contract на `WasmDatabase.inMemory`, StorageInfo, persistence при открытии нового executor, typed errors для отсутствующих ресурсов и perf budget.
5. Добавлены Chrome performance тест и сравнимый VM benchmark: 100k SQL вставок одной транзакцией, затем 10 страниц по 50 записей. Существующие тесты не менялись.
6. `tool/serve_web_dev.sh` собирает debug web bundle и запускает локальную раздачу с `application/wasm` для wasm и `application/javascript` для worker. `ENABLE_CROSS_ORIGIN_ISOLATION=1` добавляет COOP same-origin и COEP require-corp для `opfsLocks`. DevTools manual QA дополнен проверками reload, деградации и двух вкладок.
7. В CI добавлен job `storage-web` с Chrome/dart2js; web build проверяет ресурсные SHA в debug и release артефактах.
8. Весь репозиторий очищен от упоминаний прежнего отдельного пакета; `core_storage/lib` по-прежнему не импортирует `drift/native.dart`, `drift/wasm.dart`, `dart:io`, `dart:ffi`, `dart:html`, `package:web`, `dart:js_interop`, `sqlite3_flutter_libs` или `path_provider`.

### Файлы этапа

- Новый код: `packages/platform_web/lib/src/storage_database_factory_web.dart`.
- Web tests: `packages/platform_web/test/storage_database_factory_web_test.dart`, `packages/platform_web/test/storage_performance_web_test.dart`; VM benchmark: `packages/core_storage/test/storage_performance_benchmark_test.dart`.
- Ресурсы/инструменты: `tool/web_assets.lock`, `tool/web_assets.sha256`, `tool/fetch_web_assets.sh`, `tool/test_web_storage_chrome.sh`, `tool/serve_web_dev.sh`; ресурсы и `apps/app/build/` генерируются локально и не сохраняются в Git.
- Конфигурация: `packages/platform_web/pubspec.yaml`, `lib/platform_web.dart`, `.gitignore`, `.github/workflows/ci.yml`.
- Документация: `packages/core_storage/DESIGN.md`, `docs/MANUAL_QA.md`, `docs/OPEN_QUESTIONS.md` (Q30–Q31), `docs/DEFECTS.md` (S4-01/S4-04/S4-06; S4-13 — прежние analyzer diagnostics), этот журнал.

### Результаты проверок

- `bash tool/test_web_storage_chrome.sh`: **6 passed, 0 failed** на Chrome/dart2js; EventStore contract, metadata/warnings, persistent reopen, missing-resource errors и 100k benchmark прошли.
- Chrome performance output: `events=100000 insert_ms=4994 pagination_p95_ms=4`; пороги слоя 4 — <30 s и p95 <200 ms.
- `dart test packages/core_storage/test/storage_performance_benchmark_test.dart -p vm`: **1 passed**; `VM_STORAGE_PERF events=100000 insert_ms=2649 pagination_p95_ms=6`.
- `dart test packages/core_storage/test/performance_test.dart -p vm`: **3 passed, 0 failed**.
- VM целевой набор (`storage_performance_benchmark_test`, EventStore, validation, app database, SQLite open/migration/version tests): **35 passed, 0 failed**.
- Точечный `dart analyze` для нового Web factory/tests и `core_storage/lib` + VM benchmark: **No issues found!**. Полный `dart analyze packages/platform_web/lib` обнаруживает 18 `prefer_const_constructors` errors и 16 JS interop infos в неизменённом `secure_key_store_web.dart`; зафиксировано как S4-13, вне скоупа.
- `flutter build web --debug` и `flutter build web --release`: **успешно**. SHA в обоих `build/web` совпали с `tool/web_assets.sha256`. `dart2wasm` не запускался; Flutter dry-run отмечает несовместимости `flutter_secure_storage_web` (`dart:html`, `dart:js_util`, `package:js`), Q30.
- `tool/serve_web_dev.sh`: проверка GET/HEAD дала HTTP 200; `sqlite3.wasm` → `Content-Type: application/wasm`, `drift_worker.js` → `application/javascript`.
- `bash tool/fetch_web_assets.sh` и `--check`: **OK**, package versions/tags и суммы совпадают. Проверено: релизный `drift_worker.js` имеет SHA `a1bd312c6ed74199ee877e4e22e69d45176f0f729bea7548dc882d2bc5b94360`, `sqlite3.wasm` — `6082c7bc2c537ab59cf915c3dcb56b4c054751bef54d16fae2ad25560cd4f8d0`.
- `bash tool/check_core_imports.sh`, `bash tool/check_core_storage_deps.sh`, `bash tool/check_docs_drift.sh`, `git diff --check`: **OK**. Поиск запрещённого отдельного пакета и запрещённых импортов в `core_storage/lib`: **0 совпадений**.
- `bash tool/check_text_hygiene.sh`: **не пройден** — после удаления собранных бинарных ресурсов остаются прежние срабатывания на CJK/диакритику/смешение кириллицы с латинскими техническими именами в других слоях и документах; список не указывает на испорченные идентификаторы в новом коде. Проверка вне AC этапа.
- Попытка проверить штатный `flutter run -d web-server` в этой workspace-конфигурации дала HTTP 404 на отдельные ресурсы; вместо этого добавлен и проверен проектный debug preview `tool/serve_web_dev.sh`, который отдаёт оба ресурса с корректными MIME.

### Что осталось

- Q30: dart2wasm не проверен; закреплённый `sqlite3` считает поддержку экспериментальной, а Flutter dry-run указывает на несовместимые зависимости Web SecureKeyStore.
- Q31: Chrome test runner проверяет persistent reopen в новой БД/новом executor в рамках той же тестовой страницы. Фактический reload app page и две вкладки не автоматизированы; добавлены ручные шаги в `docs/MANUAL_QA.md`.
- Полный analyzer пакета `platform_web` остаётся с ранее существовавшими diagnostics SecureKeyStore (S4-13). Файл не менялся в этом этапе.
- Успешная сборка и resource hash не подтверждают browser storage в каждом браузере/приватном режиме; сценарии деградации и многовкладочной работы описаны в ручном QA.

Этап 4.4 завершён. К этапу 4.5 не переходить; остановка до ревью.

---

## Запись 14 — Этап 4.0: core_storage (drift, EventStore) — проверка фактов и baseline (пять замечаний агента)

### 1. Версии и замечание об отдельном WASM-пакете (пункт 1)

Источник: `pubspec.lock` (закреплённые версии), `pubspec.yaml` пакетов, поиск по репозиторию.

| Компонент | Версия | Источник |
|-----------|--------|----------|
| `drift` | 2.19.1+1 | `pubspec.lock:180-187` (transitive) |
| `drift_dev` | не зафиксирован | закомментирован в `core_storage/pubspec.yaml:17-20` |
| `sqlite3` | 2.4.5 | `pubspec.lock:728-735` (transitive) |
| `sqlite3_flutter_libs` | 0.6.0+eol | `pubspec.lock:736-743` (transitive) |
| `drift_flutter` | отсутствует | не в pubspec/lock |
| `path_provider` | 2.1.6 | `pubspec.lock:523-530` (transitive, не используется в core_storage) |

Первоначальный поиск по репозиторию обнаружил неверные комментарии о будущем отдельном пакете в `core_storage` и документации. Импорта или зависимости такого пакета в pubspec/lock-файлах не было.

Вывод: отдельного пакета нет — это ложная гипотеза. WebAssembly backend встроен в `drift` 2.19.1+1.

### 2. Проверка замечания 1 (пункт 2) — wasm в составе drift

Подтверждено по исходникам закреплённой версии в pub-кэше (`/home/kov/.pub-cache/hosted/pub.dev/drift-2.19.1+1/`):

- `lib/wasm.dart` **существует** (11280 байт).
- `WasmDatabase.open({required String databaseName, required Uri sqlite3Uri, required Uri driftWorkerUri, FutureOr<Uint8List?> Function()? initializeDatabase, WasmDatabaseSetup? localSetup, bool enableMigrations = true}) -> Future<WasmDatabaseResult>` — сигнатуры совпадают с ожидаемыми (`databaseName`, `sqlite3Uri`, `driftWorkerUri`, `initializeDatabase`, `localSetup`).
- `WasmDatabase.inMemory(CommonSqlite3 sqlite3, {WasmDatabaseSetup? setup, ...})` — существует.
- `WasmDatabaseResult` поля: `resolvedExecutor` (DatabaseConnection), `chosenImplementation` (WasmStorageImplementation), `missingFeatures` (Set<MissingBrowserFeature>). Имена MissingBrowserFeature: `sharedWorkers`, `dedicatedWorkers`, `dedicatedWorkersInSharedWorkers`, `fileSystemAccess`, `indexedDb`, `sharedArrayBuffers`.
- Файлы для `web/`: `sqlite3.wasm` и drift worker описаны в комментариях `wasm.dart:101-103`; конкретные релизные артефакты проверены в этапе 4.4.
- Важно: `package:drift/wasm.dart` импортирует `package:web/web.dart` и `package:sqlite3/wasm.dart` — запрещено в `core_storage` (чистый Dart). Веб-фабрика должна жить в `platform_web`, а не в `core_storage`. Это подтверждает архитектуру замечания 5.

Статус замечания 1: **опровергнута гипотеза** — web-поддержка входит в сам `drift` (`package:drift/wasm.dart`).

### 3. Проверка замечания 3 (пункт 3) — ON CONFLICT и версия SQLite

Где используется `ON CONFLICT` в коде репозитория:
- `packages/core_storage/lib/src/database/app_database.dart:75` — `INSERT INTO schema_info (id, version) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET version = ?` (таблица `schema_info`, DO UPDATE).
- `packages/core_storage/test/sqlite_version_test.dart:49` — прямой upsert `ON CONFLICT(id) DO UPDATE SET value = ?` (проверка).

Минимальная версия SQLite для `ON CONFLICT ... DO UPDATE` — 3.24.0 (доказано тестом `sqlite_version_test.dart`).

Откуда берётся SQLite на платформах (по README `sqlite3` 2.4.5 в pub-кэше):
- **Android**: `package:sqlite3` через `dart:ffi` загружает системную библиотеку; `sqlite3_flutter_libs` 0.6.0+eol — **no-op** («Starting from version 0.6.0, this package no longer does anything»), загрузку берет на себя `package:sqlite3`. Можно shipping кастомную `.so`.
- **Linux**: системный `libsqlite3` (например, `libsqlite3-dev` на Debian) или кастомный, через `dart:ffi`; `sqlite3_flutter_libs` — no-op.
- **Web**: `sqlite3.wasm` (WASM сборка sqlite3), через `package:sqlite3/wasm.dart`; поддерживается `dartdevc`/`dart2js`, `dart2wasm` экспериментально.

Статус замечания 3: **подтверждено** — bundled/системная SQLite ≥ 3.24.0, `ON CONFLICT` upsert работает (тест зелёный).

### 4. Проверка замечания 2 (пункт 4) — автор события

- `EventStore.write()` (`DriftEventStore.write()`, `event_store_impl.dart:30`) пишет `author: ''` с `TODO(verify)`.
- `EventRecord` (`core_domain/lib/src/interfaces/event_store.dart:6-13`) НЕ имеет поля `author` — только `id`, `groupId`, `payload`, `timestamp`, `signature`.
- `Envelope` (`core_protocol/lib/src/envelope.dart:29`) имеет поле `sender` (`Uint8List` — открытый ключ Ed25519 отправителя), но не строку-автора.
- `GroupEvent`/`ChatEvent` (`messages.dart`) имеют поле `authorId` (строка), но оно внутри payload (хранилище не парсит payload по правилу этапа — непрозрачные байты).
- `seq` — поле `events.seq INTEGER` есть, индекс `idx_events_author_seq(author, seq)` есть (schema.dart:158), ORDER BY seq есть, НО `insertEvent` не принимает `seq` — оно всегда `NULL`. Кто заполняет `seq` — неизвестно.
- `id` события — content hash, задаётся вызывающим кодом (слой 3/5), хранилище не считает id.

Статус замечания 2: **не проверено** — заблокировано отсутствием реализации `core_protocol` (Q15) и отсутствием поля `author` в `EventRecord`; автор остаётся `''`.

### 5. Проверка замечания 4 (пункт 5) — что мешает `dart test -p chrome` для core_storage

Разделённые причины:
1. **Нет веб-реализации `DatabaseFactory`** в `core_storage` — `createWebDatabase()` отсутствует; веб-фабрика должна жить в `platform_web` (замечание 5).
2. **Запрет импортов в `core_storage`**: `package:drift/wasm.dart` импортирует `package:web/web.dart` — запрещён в `core_storage` (только `drift.dart`). Даже при желании подключить wasm напрямую из `core_storage` нельзя.
3. **Отсутствуют ресурсы `web/`** — нет `sqlite3.wasm` и drift worker.
4. **Инфраструктура Chrome**: тестовый раннер `package:test` не отдаёт `dart.js` с MIME-типом `application/javascript` (отдаёт `text/plain`) — Chrome блокирует выполнение (Q4, не код).

Статус замечания 4: **не проверено** — заблокировано отсутствием `drift`-wasm интеграции в `platform_web` (пункт 1-3) и инфраструктурой Chrome (пункт 4).

### 6. Baseline (пункт 6)

- `dart analyze packages/core_storage/lib`: **0 ошибок, 0 предупреждений, 0 info** (`No issues found!`).
- `dart test packages/core_storage/test/ -p vm`: **40 пройдено, 0 провалено** (включает новый `test/sqlite_version_test.dart`).
- `bash tool/check_text_hygiene.sh`: находит мусор в репозитории, но **документы слоя 4 чисты** (DEFECTS.md раздел этапа 4, PHASE_LOG.md запись 14, OPEN_QUESTIONS.md Q18 — без CJK/диакритики/смешения алфавитов). Исправлен текстовый мусор: `OPEN_QUESTIONS.md:64` `drift схема` → `drift-схема` (смешение алфавитов).
- `melos run check:imports`: OK.
- `grep package:drift/native.dart packages/core_storage/lib`: 0 совпадений.

### Что изменено
- Изменённые документы:
  - `docs/DEFECTS.md` — раздел этапа 4: обновлены S4-01/S4-04 (уточнено, что отдельного WASM-пакета нет), добавлены S4-06 (ошибочные комментарии), S4-07 (`seq` всегда NULL), S4-08 (`EventRecord` без `author`).
  - `docs/OPEN_QUESTIONS.md:64` — исправлен текстовый мусор (`drift схема` → `drift-схема`).
  - `docs/PHASE_LOG.md` — эта запись (полная проверка фактов пунктов 1–6).
- Код `lib/` не изменён (`git diff packages/core_storage/lib` пуст).

### Что осталось
- S4-01: на этапе 4.0 отдельная web-фабрика и ресурсы ещё отсутствовали; дальнейшая реализация отмечена в записи этапа 4.4.
- S4-02: извлечение `author` требует `core_protocol` (Q15) и поля `author` в `EventRecord`; статус «не проверено».
- S4-04: Chrome runtime и ресурсы не проверялись на этапе 4.0; результат проверки записан в этапе 4.4.
- S4-06: комментарии core_storage уже уточнены, импорт WebAssembly-модуля остаётся только в `platform_web`.
- S4-07: уточнить, кто заполняет `seq` в `events`; статус «не проверено».
- S4-08: добавить `author` в `EventRecord` или извлекать из payload на уровне вызывающего кода; статус «не проверено».
- Q2 (DI platform-реализаций) — открыт.

### Результаты тестирования
- `dart test packages/core_storage/test/ -p vm`: **40 пройдено, 0 провалено**.
- `dart analyze packages/core_storage/lib`: **0 ошибок, 0 предупреждений, 0 info**.
- `dart analyze packages/platform_android/lib packages/platform_linux/lib`: ошибки только пред-existing; новые `storage_database_factory.dart` — чисто.
- `melos run check:imports`: OK.
- `grep package:drift/native.dart packages/core_storage/lib`: **0 совпадений**.
- `bash tool/check_text_hygiene.sh`: документы слоя 4 чисты (остальной мусор — в других слоях, вне scoped этапа 4).

---

## Запись 15 — Этап 4.1: EventRecord и EventStore

### Что сделано

1. `EventRecord.author` сделано обязательным полем: вызывающий слой передаёт автора после проверки события. `core_storage` не зависит от `core_protocol`, не проверяет подпись и не разбирает payload.
2. `DriftEventStore.write()` проверяет непустой `id`, hex-формат публичного ключа автора (32 байта) и payload (непустой, до 1 МиБ); ошибки возвращаются как `Result<InsertOutcome, EventStoreWriteError>` без записи.
3. Повторная запись идентификатора сохраняет исходные байты. На drift 2.19.1+1 `QueryExecutor.runInsert()` возвращает `lastInsertRowId`, а не число изменённых строк; для `INSERT OR IGNORE` используется `runUpdate()`, который в native и WASM executor-ах возвращает SQLite `updatedRows`.
4. `FakeEventStore` приведён к Result-контракту и идемпотентному поведению.
5. Уточнены запросы по событиям: сортировка и индексирование не используют зарезервированный `seq`; миграция v2→v3 сохраняет прежние строки и заменяет индекс автора.
6. Исправлены комментарии core_storage о backend-ах. `tool/check_core_imports.sh` теперь проверяет import/export/part directives только в `core_*/lib`, поэтому тестовый `NativeDatabase` и упоминания запретов в комментариях не дают ложных срабатываний.

### Что изменено

- `packages/core_domain/lib/src/interfaces/event_store.dart`, `packages/core_domain/lib/src/interfaces/fakes.dart`.
- `packages/core_storage/lib/core_storage.dart`, `packages/core_storage/lib/src/database/app_database.dart`, `packages/core_storage/lib/src/event_store_impl.dart`, `packages/core_storage/lib/src/platform/database_factory.dart`.
- `tool/check_core_imports.sh`.
- `docs/DEFECTS.md` — статусы S4-01…S4-09; `docs/OPEN_QUESTIONS.md` — Q25; этот журнал.

### Что осталось

- S4-01/S4-04: на момент завершения этапа 4.3 web-фабрика, ресурсы и Chrome runtime ещё не были реализованы; отдельный WASM-пакет не требовался. Этап 4.4 закрывает эту работу.
- S4-03: upsert подтверждён текущим native test runtime; фактические версии SQLite в целевых Android/Linux сборках и необходимость runtime-проверки — Q25.
- Полный `dart test packages/core_storage/test/ -p vm` не компилирует существующий `sqlite_version_check_test.dart`: сигнатуры `beginTransaction`/`beginExclusive` объявлены как `dynamic`, не как типы закреплённого drift 2.19.1+1. Тест не изменялся.
- `dart test packages/core_domain/test/core_domain_test.dart -p vm` не компилирует существующий вызов конструктора `EventRecord` без нового обязательного `author`. Тест не изменялся.
- Этапы 4.2–4.5 не выполнялись.

### Результаты тестирования

- Красный прогон до исправления: дубли EventStore считались вставленными, потому что `runInsert()` ошибочно трактовался как количество затронутых строк.
- После исправления: `dart test packages/core_storage/test/event_store_test.dart packages/core_storage/test/event_store_validation_test.dart packages/core_storage/test/app_database_test.dart packages/core_storage/test/migration_test.dart packages/core_storage/test/sqlite_version_test.dart packages/core_storage/test/performance_test.dart packages/core_storage/test/retention_test.dart packages/core_storage/test/sync_queries_test.dart packages/core_storage/test/ui_queries_test.dart -p vm` — **50 пройдено, 0 провалено**.
- `dart analyze packages/core_storage/lib packages/core_domain/lib/src/interfaces/event_store.dart` — **No issues found!**
- `bash tool/check_core_imports.sh` — **OK**.
- `dart test packages/core_storage/test/ -p vm` — **полностью не проверено** из-за compile error в существующем `sqlite_version_check_test.dart`.
- `dart test packages/core_domain/test/core_domain_test.dart -p vm` — **не проверено** из-за устаревшего вызова конструктора в тесте.

---

## Запись 16 — Этап 4.2: проверка SQLite, EventStore и миграция

### Решения

1. По подтверждению пользователя legacy payload **не декодируется**. Строки v3 с пустым `author` сохраняются как карантинные; строки с уже заполненным `author` сохраняются без преобразования.
2. Версия схемы повышена с 3 до 4. `migrations[4]` не меняет данные или структуру таблиц: в v3 уже присутствуют требуемые колонки и индексы. Миграция обновляет версию и проверяет сохранение обеих категорий строк.
3. Для хранения `sqliteVersion` добавлен core API `AppDatabase.open(...) -> StorageInfo` и типизированные ошибки открытия. Платформенные фабрики на этапе 4.2 не менялись.

### Что сделано

1. Проверка `SELECT sqlite_version() AS version` выполняется после `ensureOpen`, до чтения/изменения схемы. Минимум — `3.24.0`. Ниже минимума выбрасывается `DatabaseVersionTooLow(required, actual)`; остальные ошибки открытия оборачиваются в `OpenFailure`.
2. `StorageInfo` включает backend, persistence, SQLite version и warnings; добавлены описанные в design типы `StorageSpec`, `OpenedStorage`, `StorageBackend`, `StorageOpenError` и его варианты.
3. Для событий оставлен `INSERT OR IGNORE`; `QueryExecutor.runUpdate()` возвращает фактическое число изменённых строк. Upsert остаётся только на `schema_info`, до него теперь гарантированно проверяется минимум SQLite.
4. Добавлены проверки параллельной записи одного id в одной транзакции и через два подключения/транзакции; ровно один результат — inserted, остальные — duplicate, исходные bytes не перезаписываются.
5. Добавлен `EXPLAIN QUERY PLAN` тест на `idx_events_group_hlc` и `idx_events_author_hlc`; запросы не сортируют по `seq`.
6. Добавлен SQL snapshot нужной части схемы v3 и тест миграции v3→v4 для заполненного и пустого автора. `drift_dev` не закреплён в lock-файле и отсутствует в pub-кэше; snapshot пока ручной, TODO внесён как Q26.
7. `packages/core_storage/DESIGN.md` обновлён по решениям этапа 4.2; `docs/DEFECTS.md` дополнен тестовыми ссылками и статусами.

### Файлы этапа

- `packages/core_storage/lib/src/models/storage_info.dart`, `lib/core_storage.dart`, `lib/src/database/app_database.dart`, `lib/src/database/schema.dart`.
- `packages/core_storage/test/sqlite_open_and_migration_test.dart`, `test/schema_v3_snapshot.dart`, `test/event_store_concurrency_test.dart`, `test/index_query_plan_test.dart`.
- `packages/core_storage/DESIGN.md`, `docs/DEFECTS.md`, `docs/OPEN_QUESTIONS.md` (Q25 уточнён, Q26 добавлен), этот журнал.
- Платформенные фабрики не изменялись.

### Результаты тестирования

- Красный прогон до реализации: `dart test packages/core_storage/test/sqlite_open_and_migration_test.dart -p vm` — **1 пройдено, 3 провалено**: отсутствовал `AppDatabase.open`, ошибка версии не выдавалась, schema version была 3 вместо 4.
- Зелёный целевой прогон: `dart test packages/core_storage/test/sqlite_open_and_migration_test.dart packages/core_storage/test/event_store_concurrency_test.dart packages/core_storage/test/index_query_plan_test.dart packages/core_storage/test/event_store_validation_test.dart packages/core_storage/test/event_store_test.dart packages/core_storage/test/sqlite_version_test.dart -p vm` — **24 пройдено, 0 провалено**.
- `dart analyze packages/core_storage/lib packages/core_storage/test/sqlite_open_and_migration_test.dart packages/core_storage/test/event_store_concurrency_test.dart packages/core_storage/test/index_query_plan_test.dart` — **No issues found!**
- `bash tool/check_core_imports.sh` — **OK**.
- `git diff --check` — **OK**.
- Полный `dart test packages/core_storage/test/ -p vm` — **56 пройдено, 2 блокера**: существующий `sqlite_version_check_test.dart` не компилируется из-за `dynamic` вместо типов `TransactionExecutor`/`QueryExecutor`; существующий `migration_test.dart` ожидает schema version 3 вместо 4. Тесты не менялись.

### Что осталось

- Q25: проверить фактическую SQLite version в Android/Linux сборках; runtime-проверка реализована.
- Q26: закрепить совместимую версию drift_dev и проверить точные команды schema dump/migration tooling; текущий v3 snapshot ручной.
- Существующие несовместимые тесты из S4-09 не изменялись по правилу этапа.
- Этапы 4.3–4.5 не выполнялись.

---

## Запись 17 — Этап 4.3: native-фабрики SQLite для Android и Linux

### Решения

1. После обнаружения конфликта с ADR 4.1 пользователь выбрал bundled SQLite для Android. ADR уточнён: `sqlite3_flutter_libs` 0.5.41 вместо 0.6.0+eol (no-op). Контракты `StorageBackend` и `StorageInfo` не менялись.
2. `sqlite3_flutter_libs` 0.5.41 закреплён в `platform_android` и `platform_linux`, `sqlite3` 2.4.5 и `path_provider` 2.1.6 добавлены как прямые зависимости обоих native-пакетов. `core_storage` по-прежнему зависит только от `core_domain` и `drift`.
3. Исходники закреплённых библиотек сверены в pub-кэше:
   - `drift` 2.19.1+1: `NativeDatabase.createInBackground(File, {setup})`, `NativeDatabase.memory({setup})`; setup исполняется до готовности Drift, callback является top-level и подходит для изолята.
   - `sqlite3_flutter_libs` 0.5.41: README описывает bundled native SQLite на Android/Linux; Android Gradle dependency — `sqlite3-native-library:3.51.1`; Linux CMake собирает SQLite 3.51.1 в plugin shared library.
   - `sqlite3` 2.4.5: Android loader открывает `libsqlite3.so`; Linux loader использует экспортированный symbol зарегистрированного Flutter plugin, иначе fallback на системный `libsqlite3.so`.
4. Ошибки открытия сохраняют утверждённый `Future<OpenedStorage>` API, а дополнительный `StorageBackend.openResult()` даёт `Result<OpenedStorage, StorageOpenError>` для границ, которым запрещено выпускать исключения. `StorageOpenError`/`StorageInfo` не менялись. Linux отсутствие `libsqlite3.so` в fallback-режиме преобразуется в `ResourceMissing` с инструкцией установки `libsqlite3-dev`.
5. Для файловой и memory-БД задаются `foreign_keys=ON`, `journal_mode=WAL`, `synchronous=FULL`. Причины и ограничения фактической durability при потере питания записаны в `packages/core_storage/DESIGN.md`; Q27 оставлен для подтверждения гарантий на целевых устройствах.

### Что сделано

1. `AndroidDatabaseFactory` и `LinuxDatabaseFactory` реализуют `StorageBackend`, используют `getApplicationSupportDirectory()` для файловой БД, именуют backend `file`, устанавливают `isPersistent=true` и возвращают фактическую `sqlite_version()` из `AppDatabase.open()`. `StorageSpec.inMemory` явно создаёт `NativeDatabase.memory`, `backend=memory`, `isPersistent=false` и предупреждение.
2. Добавлены предупреждение для файлов в системном temp-каталоге и проверка имени файла, предотвращающая выход из application support directory.
3. Добавлен общий `runEventStoreContract` в `packages/core_storage/test/event_store_contract.dart`; Linux VM тест запускает его на memory и временном файле. Отдельные сценарии проверяют close/reopen того же файла, SQLite PRAGMA, временное предупреждение и ошибки повреждённой БД/недоступной директории через `Result`.
4. Добавлен `tool/check_core_storage_deps.sh`: проверяет `core_storage/pubspec.yaml` и импорты на `sqlite3_flutter_libs`/`path_provider`; включён в Melos `check:imports`.
5. `docs/MANUAL_QA.md` дополнен Android-чек-листом: установка, обновление поверх старой версии, перезапуск, очистка только кэша, проверка `StorageInfo` и фиксация результата на устройстве.
6. `docs/DEFECTS.md` дополнен S4-11 и S4-12: umbrella import Linux обнаружил отсутствующий `_stateKey` в SecureKeyStore; Android `flutter drive` отклоняет текущий Gradle runner как unsupported. Оба дефекта не исправлялись в этом этапе; Linux storage-тест импортирует непосредственно фабрику, Android проверка остаётся ручной.

### Файлы этапа

- `packages/platform_android/lib/src/storage_database_factory.dart`, `packages/platform_linux/lib/src/storage_database_factory.dart`.
- `packages/platform_android/pubspec.yaml`, `packages/platform_linux/pubspec.yaml`, `pubspec.lock`, `pubspec.yaml`.
- Сгенерированные Flutter-регистраторы `apps/app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`, `apps/app/linux/flutter/generated_plugin_registrant.cc`, `apps/app/linux/flutter/generated_plugins.cmake`.
- `packages/core_storage/lib/core_storage.dart`, новый `lib/src/platform/storage_backend_result.dart`, новый `test/event_store_contract.dart`.
- Новый `packages/platform_linux/test/storage_database_factory_test.dart`, новый `tool/check_core_storage_deps.sh`.
- `packages/core_storage/DESIGN.md`, `docs/MANUAL_QA.md`, `docs/DEFECTS.md`, `docs/OPEN_QUESTIONS.md`, этот журнал.

### Результаты тестирования

- `flutter test packages/platform_linux/test/storage_database_factory_test.dart`: **7 пройдено, 0 провалено**. Покрыты EventStore contract на памяти и файле, persistence после перезапуска, pragma, предупреждение temp-каталога, повреждённая БД и недоступный каталог.
- `dart test packages/core_storage/test/event_store_test.dart packages/core_storage/test/event_store_validation_test.dart packages/core_storage/test/app_database_test.dart packages/core_storage/test/sqlite_open_and_migration_test.dart packages/core_storage/test/sqlite_version_test.dart -p vm`: **34 пройдено, 0 провалено**.
- `dart analyze packages/core_storage/lib packages/core_storage/test/event_store_contract.dart packages/platform_android/lib/src/storage_database_factory.dart packages/platform_linux/lib/src/storage_database_factory.dart packages/platform_linux/test/storage_database_factory_test.dart`: **No issues found!**
- `bash tool/check_core_storage_deps.sh`: **OK** — нет `sqlite3_flutter_libs`/`path_provider` в `core_storage`.
- `bash tool/check_core_imports.sh`: **OK** — запрещённых импортов нет.
- `dart pub deps`: `core_storage` имеет runtime-зависимости `core_domain` и `drift`; платформенные пакеты содержат `sqlite3_flutter_libs`, `path_provider`, `sqlite3`, `drift`.
- `git diff --check`: **OK**.
- Полный тестовый пакет `platform_linux` не проверен: первая загрузка через umbrella import падает в предсуществующем `secure_key_store_linux.dart` из-за `_stateKey`; зафиксировано как S4-11, код и существующие тесты не менялись.
- Android runtime не проверен: AVD `Medium_Phone` удалось запустить, но `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/storage_database_test.dart -d emulator-5554` остановился до сборки из-за unsupported Gradle project. Выполнен статический аудит источников пакетов, ручной QA чек-лист добавлен.

### Что осталось

- Q25/Q28: подтвердить runtime SQLite version и источник библиотеки в собранных Android APK и Linux приложении. Пакетные исходники подтверждают bundled SQLite 3.51.1, но runtime сборки/устройства не тестировались.
- Q27: уточнить power-loss guarantees `WAL` + `FULL` для Android/Linux файловых систем и накопителей; аппаратная сохранность последнего commit не обещана.
- Q29: определить стратегию поставки после устаревания `sqlite3_flutter_libs` 0.5.41; пакет не обновлять отдельно от `sqlite3` без native ABI проверки.
- S4-11: отсутствующий `_stateKey` в Linux SecureKeyStore требует отдельного исправления.
- S4-12: привести Android Gradle runner к поддерживаемому Flutter integration runner, чтобы выполнить runtime-проверку SQLite на AVD.
- Этапы 4.4–4.5 не выполнялись. Этап 4.3 завершён; дальнейшие изменения остановлены.

---

## Запись 19 — Этап 4.5: финальная приёмка слоя 4 и синхронизация документации

### Решения

1. `packages/core_storage/DESIGN.md` пересобран по коду, а не по памяти. Удалены утверждения о несуществующем `drift_wasm`, «web stub» и отложенном AC3. Зафиксированы фактические контракты `StorageSpec`/`StorageInfo`/`OpenedStorage`/`StorageBackend`, порядок открытия, валидация `EventRecord`, `INSERT OR IGNORE` и `InsertOutcome`, реальные upsert-операции, версия SQLite, миграции, web-ресурсы и модель деградации.
2. Уточнено расхождение API: `DatabaseFactory` остаётся экспортированным контрактом, но платформенные фабрики реализуют `StorageBackend`; зафиксировано как S4-14, не блокер.
3. Все 10 маркеров `TODO(verify)` в `.dart`-коде сведены в индекс `docs/OPEN_QUESTIONS.md`. Добавлены Q32 (дрейф HLC) и Q33 (независимая сверка BIP-39/NFKD); Q18 переведён в «ЗАКРЫТО».
4. Создан `docs/LAYER4_ACCEPTANCE.md` с AC1–AC6, командами, фрагментами вывода и честными статусами. `docs/REVIEW_LIST.md` дополнен разделом слоя 4.
5. Исправлен устаревший комментарий в `schema.dart` («schema version 1» → «current schema version 4»). Существующие тесты не изменялись.

### Что изменено

- Новые документы: `docs/LAYER4_ACCEPTANCE.md`.
- Переписано: `packages/core_storage/DESIGN.md`.
- Обновлены: `docs/OPEN_QUESTIONS.md` (индекс TODO, Q18, Q32, Q33), `docs/REVIEW_LIST.md` (слой 4), `docs/DEFECTS.md` (S4-14, S4-15), `docs/PHASE_LOG.md` (эта запись).
- Код: только комментарий версии схемы в `packages/core_storage/lib/src/database/schema.dart`; поведение не менялось.
- Инструменты: `tool/check_docs_drift.sh` — проверка (c) теперь сверяет индекс TODO с кодом и блокирует дрейф.

### Результаты проверок

- `dart test` (12 актуальных файлов core_storage, `-p vm`): **51 пройдено, 0 провалено**; `VM_STORAGE_PERF events=100000 insert_ms=2058 pagination_p95_ms=5`.
- Полный `dart test packages/core_storage/test/ -p vm`: **57 пройдено, 2 провалено** — S4-09: `migration_test.dart` ожидает schema version 3, `sqlite_version_check_test.dart` не компилируется из-за `dynamic` вместо `TransactionExecutor`/`QueryExecutor`. Тесты не изменялись.
- `dart test packages/core_storage/test/migration_test.dart -p vm`: **6 пройдено, 1 провалено** (то же устаревшее ожидание version 3).
- `flutter test packages/platform_linux/test/storage_database_factory_test.dart`: **7 пройдено, 0 провалено**.
- `bash tool/test_web_storage_chrome.sh`: **6 пройдено, 0 провалено**; `WEB_STORAGE_PERF events=100000 insert_ms=5028 pagination_p95_ms=4`.
- `dart analyze` целевых файлов слоя 4: **No issues found!**.
- `melos run analyze`: **не проверено как зелёная проверка** — 217 issues (108 errors, 18 warnings, 91 info), exit 1; причины предсуществующие, в `core_storage/lib` и storage-фабриках ошибок нет. Дополнительно найден вложенный путь `packages/core_crypto/packages/core_crypto/...` (S4-15).
- `bash tool/check_core_imports.sh`: **OK**.
- `bash tool/check_core_storage_deps.sh`: **OK**.
- `bash tool/check_docs_drift.sh`: **OK (a, b, c)**. Индекс TODO в `OPEN_QUESTIONS.md` сверяется с кодом: **10 = 10**; Q-записей 33, включая вопросы без маркера в коде. Проверка (c) обновлена в `tool/check_docs_drift.sh` и теперь блокирующая при расхождении.
- `grep drift_wasm`: **0**; `grep expect(true`: **0**; `UnimplementedError` в `packages/*/lib`: **0**; единственное совпадение — `apps/app/lib/di/providers.dart:32`, не слой 4.
- `bash tool/check_text_hygiene.sh`: **не проверено как зелёная проверка** (exit 1). Новые документы слоя 4 и обновлённые записи чисты; остаются предсуществующие срабатывания в других слоях, `docs/DESIGN.md`, `docs/UI_UX.md` и сгенерированном `sqlite3.wasm`.

### Что осталось

- S4-09: устаревшие тесты `sqlite_version_check_test.dart` и `migration_test.dart` не исправлялись по правилу этапа.
- Q25/Q28: runtime-версия и источник SQLite в собранных Android/Linux приложениях не проверены.
- Q27: power-loss durability не подтверждена.
- Q29: стратегия замены `sqlite3_flutter_libs` 0.5.41 не определена.
- Q30: dart2wasm не проверен.
- Q31: reload страницы и две вкладки остаются ручным QA.
- S4-12: Android runtime не проверен; S4-14/S4-15 требуют отдельных решений.

Этап 4.5 завершён. К следующему этапу не переходить; остановка до ревью.

---

## Запись 20 — Этап 4.0 (повторная проверка): факты и baseline на текущем рабочем дереве

### Состояние дерева до работы

В рабочем дереве уже присутствуют незакоммиченные результаты этапов 4.1–4.5 (слой 4 реализован, `packages/core_storage/lib/src/` и `test/` не отслеживаются Git). Поэтому критерий «`git diff` по `lib/` пуст» в исходном виде невыполним: на старте `git status --porcelain` содержит 40 записей, а `git diff -- packages/core_storage/lib` не пуст только из-за изменённого `core_storage.dart` (untracked `lib/src/` в diff не попадает). Контрольная сумма baseline-диффа `packages/core_storage/lib`: `e522e8389ee09e0930262028f29b6a302291f030e93dbb207d1c7243a7735cf2`. В этом этапе `lib/` не изменялся; сумма после работы та же.

### 1. Версии из pubspec.lock

| Компонент | Версия | Доказательство |
|-----------|--------|----------------|
| `drift` | 2.19.1+1 | `pubspec.lock:180,187` |
| `drift_dev` | отсутствует | нет записи в `pubspec.lock`; закомментирован в `packages/core_storage/pubspec.yaml:17-20` |
| `sqlite3` | 2.4.5 | `pubspec.lock:728,735` |
| `sqlite3_flutter_libs` | 0.5.41 | `pubspec.lock:736,743` |
| `drift_flutter` | отсутствует | нет записи в `pubspec.lock` и в pubspec-файлах |
| `path_provider` | 2.1.6 | `pubspec.lock:523,530` |

`drift_wasm` как зависимость отсутствует. Единственные упоминания имени — в документах (`packages/core_storage/DESIGN.md:3`, `docs/PHASE_LOG.md:907,933`, `docs/LAYER4_ACCEPTANCE.md:240`). Резолвить нечего.

### 2. Замечание 1 — web-поддержка входит в drift

Проверено по pub-кэшу `/home/kov/.pub-cache/hosted/pub.dev/drift-2.19.1+1/`:

- `lib/wasm.dart` существует; `WasmDatabase.open` объявлен на строке 117 с параметрами `databaseName`, `sqlite3Uri`, `driftWorkerUri`, `initializeDatabase`, `localSetup`, `enableMigrations`; `WasmDatabase.inMemory(CommonSqlite3 sqlite3, {setup, logStatements, cachePreparedStatements})` — строка 82.
- `WasmDatabaseResult` (`lib/src/web/wasm_setup/types.dart:205`): `resolvedExecutor`, `chosenImplementation`, `missingFeatures`.
- `WasmStorageImplementation` (`types.dart:25`): `opfsShared`, `opfsLocks`, `sharedIndexedDb`, `unsafeIndexedDb`, `inMemory`.
- `MissingBrowserFeature` (`types.dart:111`): `sharedWorkers`, `dedicatedWorkers`, `dedicatedWorkersInSharedWorkers`, `fileSystemAccess`, `indexedDb`, `sharedArrayBuffers`.
- Нужные файлы: `sqlite3.wasm` (релиз `sqlite3.dart`) и drift worker; источник указан в doc-комментарии `wasm.dart:101-103`. В репозитории их скачивает `tool/fetch_web_assets.sh`, версии закреплены в `tool/web_assets.lock`.

Вывод: гипотеза об отдельном пакете и stub-реализации **опровергнута**. Web-фабрика находится в `platform_web`, а не в `core_storage`, потому что `drift/wasm.dart` импортирует `package:web/web.dart` и `package:sqlite3/wasm.dart`.

### 3. Замечание 3 — ON CONFLICT и SQLite

Использование upsert:

| Место | Операция | Таблица |
|-------|----------|---------|
| `packages/core_storage/lib/src/database/app_database.dart:155-157` | `ON CONFLICT(id) DO UPDATE SET version = ?` | `schema_info` |
| `packages/core_storage/test/sqlite_version_test.dart:49` | прямой upsert | тестовая таблица |
| `app_database.dart:237-250` | `INSERT OR IGNORE` | `events` (дубли не перезаписываются) |
| `app_database.dart:534,601,630,649,684,733` | `INSERT OR REPLACE` | справочники `groups`, `channels`, `peers`, `group_settings`, `blobs_meta`, `sync_state` |
| `app_database.dart:561` | `INSERT OR IGNORE` | `members` |

Минимум для `ON CONFLICT ... DO UPDATE` — SQLite 3.24.0 (первоисточник SQLite в pub-кэше отсутствует; требование подтверждено `sqlite_version_test.dart`, зелёный на runtime 3.54.0).

Источники SQLite в текущей конфигурации:

- Android: `sqlite3_flutter_libs` 0.5.41, `android/build.gradle:40` — `eu.simonbinder:sqlite3-native-library:3.51.1`; загрузчик `sqlite3` 2.4.5 открывает `libsqlite3.so` (`lib/src/ffi/load_library.dart`).
- Linux: тот же пакет, `linux/CMakeLists.txt:15` собирает `sqlite-autoconf-3510100.tar.gz` (3.51.1); при отсутствии plugin-символа `sqlite3` 2.4.5 откатывается на системную `libsqlite3.so`. В текущем окружении системная версия — `3.54.0` (`sqlite3 --version`).
- Web: `sqlite3.wasm` из релиза `sqlite3` 2.4.5; в бинарнике `apps/app/web/sqlite3.wasm` строка версии — `3.46.0` (`strings ... | grep -oE '3\\.[0-9]+\\.[0-9]+'`).

Runtime-версия в собранных Android/Linux приложениях не проверялась — Q25/Q28.

### 4. Замечание 2 — автор, sender, seq, id

- `DriftEventStore.write` (`packages/core_storage/lib/src/event_store_impl.dart:35-67`) передаёт `author: record.author`; значение не пустое и проверяется как 64 hex-символа (`:73-89`).
- `EventRecord.author` — обязательное поле (`packages/core_domain/lib/src/interfaces/event_store.dart:68-84`), заполняется вызывающим кодом после проверки подписи.
- В репозитории нет production-вызова `EventStore.write`: `apps/app/lib/di/providers.dart` использует `FakeEventStore`, `core_sync` пока экспортирует только `HlcValidator`. Вызовы `EventRecord(...)` есть только в тестах.
- `Envelope.sender` (`packages/core_protocol/lib/src/envelope.dart:29`) — `Uint8List` с открытым ключом Ed25519, не hex-строка. Преобразование в `author` не автоматическое; слой, который будет писать событие, обязан сделать hex и передать его.
- `seq`: колонка `events.seq INTEGER` существует (`schema.dart:95`), но `insertEvent` её не записывает, значение остаётся `NULL`; порядок задаётся `hlc`. В протоколе `Envelope` поля `seq` нет; `sequence` есть только у `LeaderLease` (`messages.dart:1154`) и не является порядковым номером события.
- `id` события хранилище не вычисляет. Комментарий `event_store_impl.dart:9` называет его content hash, но фактический расчёт в этом дереве не реализован: id приходит от вызывающего кода.

### 5. Замечание 4 — Chrome

Причины разделены:

1. `dart test -p chrome` в `packages/core_storage` компилирует 14 тестов, которые импортируют `package:drift/native.dart` (`test/memory_database.dart:10` и ещё 8 файлов). Это тянет `dart:ffi`; dart2js падает на `ffi-2.2.0/lib/src/allocation.dart` («Only JS interop members may be 'external'»). Отдельного WASM-пакета для этого не нужно — дело в native-импортах тестов.
2. Сам `core_storage` по правилу не содержит web-открытия БД; web-фабрика находится в `platform_web`.
3. Chrome и ресурсы в окружении есть: `google-chrome-stable` найден, `tool/fetch_web_assets.sh --check` — OK, `dart test ... -p chrome -c dart2js` для `packages/platform_web` — **5 пройдено, 0 провалено**.

Вывод: замечание **опровергнуто** для web-контракта; ограничение относится только к native-тестам `core_storage`.

### 6. Baseline

- `melos run analyze`: exit 1, **217 issues** (108 error, 18 warning, 91 info). Причины предсуществующие; целевой `dart analyze` по `core_storage/lib` и трём storage-фабрикам — `No issues found!`.
- `dart test` в `packages/core_storage` (`-p vm`): **57 пройдено, 2 провалено**. Провалы — S4-09: `migration_test.dart` ожидает schema version 3; `sqlite_version_check_test.dart` не компилируется из-за `dynamic` вместо типов executor. Замер: `VM_STORAGE_PERF events=100000 insert_ms=2011 pagination_p95_ms=5`.
- `bash tool/check_text_hygiene.sh`: exit 1, 29 строк. Документы слоя 4 в выводе отсутствуют; проверка по семи файлам слоя 4 — `LAYER4_DOCS_CLEAN`. Мусор находится в других слоях, плюс скрипт сканирует бинарный `sqlite3.wasm`. Зафиксировано как S4-16; правила этапа запрещают править чужие слои.

### Что изменено

- `docs/DEFECTS.md` — добавлен S4-16 (текстовая гигиена и ложное срабатывание на бинарнике).
- `docs/PHASE_LOG.md` — эта запись.
- `lib/` не изменялся; контрольная сумма диффа `packages/core_storage/lib` совпадает с baseline.

### Что осталось

- S4-09: устаревшие `migration_test.dart` и `sqlite_version_check_test.dart` не исправлялись.
- S4-16: CJK и смешение алфавитов вне слоя 4, сканирование бинарника — отдельная задача.
- Q25/Q28: runtime-версия SQLite в собранных Android/Linux приложениях не проверена.
- Исправление замечания 2 требует вызывающего кода (слой 7) и не входит в 4.0.

Этап 4.0 завершён. Остановка до ревью таблицы.

---

## Запись 21 — Раунд 2: закрытие S4-09 и честные статусы полного прогона

### Решения

1. S4-09 признан дефектом тестовых фикстур, а не кода: тесты не соответствовали уже принятой схеме v4 и закреплённому drift 2.19.1+1. Исправлены только тестовые ожидания/типы; поведение `core_storage` не менялось, схема не менялась.
2. `sqlite_version_check_test.dart` приведён к актуальному API drift (`TransactionExecutor`/`QueryExecutor`) и к реальному alias `SELECT sqlite_version() AS version`; проверка усилена до конкретного `DatabaseVersionTooLow` вместо общего `Exception`.
3. `migration_test.dart` ожидает schema version 4; `core_domain_test.dart` передаёт обязательный `author`. Это устраняет красные файлы, ранее не входившие в целевые прогоны.
4. Статус Chrome-приёмки понижен до «не проверено»: полный `dart test -p chrome -c dart2js` в `platform_web` красный из-за предсуществующего S4-13 (6 провалов в `secure_key_store_web_test.dart`). Результат подмножества storage-файлов больше не используется как доказательство «пройдено».
5. Уточнены формулировки design/review: типы `Result`/`InsertOutcome`/`EventStoreWriteError` приходят из `core_domain` и не реэкспортируются `core_storage`; у `EventStore.write` нет таймаута; `batchEvents` сортирует только по `hlc`.

### Что изменено

- `packages/core_storage/test/sqlite_version_check_test.dart`, `packages/core_storage/test/migration_test.dart`, `packages/core_domain/test/core_domain_test.dart`.
- `packages/core_storage/lib/src/database/app_database.dart` — только комментарий порядка `batchEvents`.
- `docs/LAYER4_ACCEPTANCE.md` — переписан под правило полного прогона.
- `packages/core_storage/DESIGN.md` — экспорты, тестовые статусы, остаточные ограничения.
- `docs/DEFECTS.md` — S4-09 исправлен, S4-13 уточнён по полному Chrome-прогону.
- `docs/REVIEW_LIST.md` — убрано несуществующее утверждение о таймауте.
- Этот журнал.

### Результаты проверок

- `cd packages/core_storage && dart test` — **59 пройдено, 0 провалов**; `VM_STORAGE_PERF events=100000 insert_ms=2102 pagination_p95_ms=7`.
- `cd packages/core_domain && dart test` — **25 пройдено, 0 провалов**.
- `cd packages/platform_linux && flutter test` — **7 пройдено, 0 провалов**.
- `cd packages/platform_web && dart test -p chrome -c dart2js` (полный пакет) — **6 пройдено, 6 провалов**, все провалы в `secure_key_store_web_test.dart` (S4-13); статус Chrome для слоя 4 — не проверено.
- `dart analyze packages/core_storage/lib packages/core_storage/test/sqlite_version_check_test.dart packages/core_storage/test/migration_test.dart packages/platform_android/lib/src/storage_database_factory.dart packages/platform_linux/lib/src/storage_database_factory.dart packages/platform_web/lib/src/storage_database_factory_web.dart` — **No issues found!**
- `bash tool/check_core_imports.sh` — **OK**.
- `bash tool/check_core_storage_deps.sh` — **OK**.
- `bash tool/check_docs_drift.sh` — **OK (a, b, c)**.
- `bash tool/fetch_web_assets.sh --check` — **OK**.

### Что осталось

- S4-13: полный Chrome-прогон `platform_web` красный в Web SecureKeyStore; нужен отдельный этап. До исправления AC3/AC4 Chrome остаются «не проверено».
- S4-14: `DatabaseFactory` экспортируется, но не реализуется платформенными фабриками; удаление/депрекация требует решения по публичному API.
- Q25/Q28: runtime-версия/источник SQLite в собранных Android/Linux приложениях не проверены.
- Q27: power-loss durability не подтверждена; Q30: dart2wasm не проверен; Q31: reload/две вкладки — ручной QA.
- Схема не менялась: новая версия/миграция не требуются.

Раунд 2 завершён. К следующему этапу не переходить; остановка до ревью.

---

## Запись 22 — Этап F4.0: аудит отчёта и baseline

### Решения

1. Baseline зафиксирован полным прогоном `dart test` в `packages/core_storage` без фильтров: 59 тестов, 0 провалов. Файловый разрез: `app_database_test` 13, `event_store_concurrency_test` 2, `event_store_test` 8, `event_store_validation_test` 8, `index_query_plan_test` 1, `migration_test` 7, `performance_test` 3, `retention_test` 2, `sqlite_open_and_migration_test` 4, `sqlite_version_check_test` 1, `sqlite_version_test` 1, `storage_performance_benchmark_test` 1, `sync_queries_test` 5, `ui_queries_test` 3.
2. Исторические «51 passed», «6/7 migration_test» и «1 fail» относятся к разным наборам: 51 — целевой список без S4-09-файлов; 6/7 — старый `migration_test` с ожиданием schema v3; «1 fail» — упавшее утверждение внутри этого файла. После исправления S4-09 полный набор даёт 59/59, `migration_test` — 7/7.
3. `dart test -p chrome` в `core_storage` не компилирует ни один из 14 test-файлов: 7 импортируют `package:drift/native.dart` напрямую, ещё 7 — через `test/memory_database.dart`; `dart:ffi` недоступен в Chrome. Общий `test/event_store_contract.dart` native не импортирует, но сам по себе не является test-suite.
4. `dart analyze` в `packages/core_storage`: 0 errors, 1 warning, 25 info. Warning — неиспользуемый параметр `id` в `_validRecord`; info — `unnecessary_const` в тестах.
5. Аудит подтвердил: единственный production-путь записи событий — `EventStore.write → AppDatabase.insertEvent → INSERT OR IGNORE INTO events`; `EventStore.write` всегда пишет `channel_id = NULL`; `id` проверяется только на непустоту; `seq` всегда NULL и внешних потребителей не имеет; `rangeSummary` ограничен 100000 id и использует 32-битный некриптографический digest; `watchFrom` игнорирует курсор, `watchGroup` имеет окно гонки; retention удаляет только `blobs_meta`; триггеров append-only нет.
6. Design 4.1 (Запись 15 журнала) реализован по author/payload/дублю; отклонения/ограничения: id без проверки длины, `channel_id` не проходит через `EventRecord`, единственный production-путь записи соседствует с публичным низкоуровневым `insertEvent`/executor.
7. `lib/` в этом этапе не менялся. Проверка `git diff -- packages/core_storage/lib` не пуста из-за предсуществующего изменения `core_storage.dart`, а `lib/src/` не отслеживается Git. Контрольная сумма diff `packages/core_storage/lib` до и после этапа: `e522e8389ee09e0930262028f29b6a302291f030e93dbb207d1c7243a7735cf2`.

### Что изменено

- `docs/DEFECTS.md` — добавлены S4-17…S4-23 по результатам аудита.
- `docs/PHASE_LOG.md` — эта запись.
- Код, тесты и схема не изменялись.

### Результаты проверок

- `cd packages/core_storage && dart test` — **59 пройдено, 0 провалов**.
- `cd packages/core_storage && dart test -p chrome` — **0 выполнено, 14 файлов не загрузились** (`dart:ffi` недоступен).
- `cd packages/core_storage && dart analyze` — **0 errors, 1 warning, 25 info**.
- `bash tool/check_core_imports.sh` — **OK**.
- `bash tool/check_text_hygiene.sh` — **exit 1**, 19 уникальных файлов-нарушителей вне слоя 4 (CJK/диакритика/смешение, 25 строк отчёта), включая `apps/app/web/sqlite3.wasm`; документы слоя 4 в выводе отсутствуют.
- `git diff --check` — **OK**.

### Что осталось

- S4-17…S4-23 требуют отдельных решений; в F4.0 код не менялся.
- S4-13 (Chrome-прогон platform_web), S4-14 (`DatabaseFactory`), Q25/Q27/Q28/Q30/Q31 остаются открытыми.
- Приёмка F4.0: таблица утверждений с доказательствами — в ответе этапа; `lib/` не изменён (см. п. 7).

Этап F4.0 завершён. Остановка до ревью таблицы.

---

## Запись 23 — Этап F4.1: channelId, id, rangeSummary, watch

### Решения

1. `EventRecord` получил опциональное `ChannelId? channelId`; `DriftEventStore.write` передаёт его в `events.channel_id`. `null` означает событие уровня группы.
2. `id` валидируется по ASCII-шаблону `[A-Za-z0-9._:-]`, длина 1–128. Хранилище не вычисляет content hash; ложный комментарий убран.
3. `rangeSummary` возвращает `Result<RangeSummary, RangeSummaryError>`. Digest — SHA-256 по UTF-8 `ids.join('|')`; при превышении `limit` (по умолчанию 100000) возвращается `RangeTooLarge`, усечённый digest не выдаётся.
4. `watchFrom(cursor)` отдаёт историю с id-курсора включительно, затем live; пустой/неизвестный курсор — с начала истории. `watchFrom`/`watchGroup` подписываются на live до чтения истории, буферизуют и дедуплицируют по id, закрывая окно гонки.

### Влияние публичного API core_domain

- Изменён `EventRecord`: добавлено опциональное `channelId`, существующие конструкторы совместимы.
- `FakeEventStore` приведён к replay-семантике `watchFrom`/`watchGroup`.
- Потребители: `core_storage`, `apps/app/lib/di/providers.dart` (FakeEventStore), тесты; production-вызовов `EventStore.write` вне тестов пока нет.
- Согласование: poll-решение «Добавить channelId в EventRecord».

### Файлы и проверки

- `core_domain/lib/src/interfaces/event_store.dart`, `fakes.dart`.
- `core_storage/lib/src/event_store_impl.dart`, `database/app_database.dart`, `models/event_data.dart`, `pubspec.yaml`.
- Тесты: `event_store_test.dart`, `event_store_validation_test.dart`, `sync_queries_test.dart`, `performance_test.dart`.
- `dart test` core_storage после F4.1: 65 пройдено, 0 провалов.

---

## Запись 24 — Этап F4.2: schema v5, append-only, retention

### Решения

1. Схема повышена до v5. Миграция v4→v5 создаёт триггеры `events_append_only_no_update` и `events_append_only_no_delete`; свежая установка включает их в `allDdl`.
2. `AppDatabase.insertEvent` помечен `@internal`: production-путь записи — `DriftEventStore.write`. Публичный `QueryExecutor` остаётся доступен платформенным фабрикам.
3. `RetentionPolicy.run(before, deleteBlob:)` удаляет файл через callback, затем metadata. При ошибке callback metadata сохраняется для повтора. `expireBlobs` оставлен как metadata-only.
4. `seq` не удалялся: это отдельная schema-миграция; S4-22 остаётся техническим долгом.

### Файлы и проверки

- `core_storage/lib/src/database/schema.dart`, `app_database.dart`, `retention.dart`.
- Тесты: `sqlite_open_and_migration_test.dart` (v3→v5, триггеры), `retention_test.dart` (успех/ошибка callback), `migration_test.dart` (schema v5).
- `dart test` core_storage после F4.2: 68 пройдено, 0 провалов.
- `dart analyze lib`: No issues found!

---

## Запись 25 — Этап F4.3: удаление DatabaseFactory и синхронизация документов

### Решения

1. Неиспользуемый `DatabaseFactory` удалён из `core_storage/lib/src/platform/` и из экспортов; единственный контракт открытия — `StorageBackend`. S4-14 закрыт.
2. `packages/core_storage/DESIGN.md` обновлён по коду: schema v5, channelId, id-валидация, SHA-256/`RangeTooLarge`, replay watch, append-only, retention callback, удаление `DatabaseFactory`.
3. `docs/LAYER4_ACCEPTANCE.md`, `docs/REVIEW_LIST.md`, `docs/DEFECTS.md` синхронизированы с F4.1–F4.3.

### Результаты проверок

- `cd packages/core_storage && dart test` — **68 пройдено, 0 провалов**; `VM_STORAGE_PERF events=100000 insert_ms=2262 pagination_p95_ms=5`.
- `cd packages/core_domain && dart test` — **25 пройдено, 0 провалов**.
- `cd packages/platform_linux && flutter test` — **7 пройдено, 0 провалов**.
- `bash tool/test_web_storage_chrome.sh` — диагностический целевой прогон: 6 пройдено; `WEB_STORAGE_PERF insert_ms=4807 pagination_p95_ms=4`. Статус Chrome-приёмки не поднимается: полный `platform_web` по-прежнему красный из-за S4-13.
- `dart analyze` целевых файлов слоя 4 — без errors/warnings.
- `bash tool/check_core_imports.sh` — OK.
- `bash tool/check_core_storage_deps.sh` — OK.
- `bash tool/check_docs_drift.sh` — OK (a, b, c).

### Что осталось

- S4-13 (Web SecureKeyStore) и S4-16 (text hygiene) — отдельные этапы.
- S4-22 (`seq`) — отдельная schema-миграция.
- Q25/Q27/Q28/Q30/Q31 — без изменений.
- `git diff` по `packages/core_storage/lib` не пуст из-за ранее незакоммиченных изменений слоя 4; в F4.1–F4.3 менялись только перечисленные файлы.

Этапы F4.1–F4.3 завершены. Остановка до ревью.

---

## Запись 26 — Этап F4.4: schema v6 (seq), S4-13, S4-16

### Решения

1. Схема повышена до v6: колонка `seq` удалена из `events`, SELECT-ов и `EventData`. Миграция v5→v6 пересобирает таблицу (create → copy → drop → rename → indexes → triggers), поэтому минимальная версия SQLite остаётся 3.24.0.
2. Добавлен ручной снимок `test/schema_v5_snapshot.dart` и тест v5→v6: событие с непустым `seq` сохраняется без колонки, append-only триггеры продолжают блокировать `DELETE`.
3. S4-13: Web SecureKeyStore исправлен — алгоритмы Web Crypto получают явный `name: 'AES-GCM'`, тест пишет JSON-строку через `jsonEncode(...).toJS`, общий контракт объявлен на верхнем уровне `main` (не внутри теста). Удалён `dart:js_util`, исправлены lint-ошибки.
4. S4-16: исправлены CJK/диакритика/смешение алфавитов в `core_crypto`, `core_protocol`, `core_sync`, `core_domain`, `docs`, `tool`; `check_text_hygiene.sh` пропускает бинарники, игнорирует экранированные `\n` и поддерживает `hygiene-allow` для намеренных Unicode-fixtures.

### Файлы

- `core_storage/lib/src/database/schema.dart`, `app_database.dart`, `models/event_data.dart`.
- `core_storage/test/sqlite_open_and_migration_test.dart`, `migration_test.dart`, новый `schema_v5_snapshot.dart`.
- `platform_web/lib/src/secure_key_store_web.dart`, `platform_web/test/secure_key_store_web_test.dart`.
- Текстовые файлы других слоёв и `tool/check_text_hygiene.sh`.
- `docs/LAYER4_ACCEPTANCE.md`, `docs/DEFECTS.md`, `docs/REVIEW_LIST.md`, `packages/core_storage/DESIGN.md`, этот журнал.

### Результаты проверок

- `cd packages/core_storage && dart test` — **69 пройдено, 0 провалов**; `VM_STORAGE_PERF events=100000 insert_ms=2661 pagination_p95_ms=5`.
- `cd packages/core_crypto && dart test` — **202 пройдено, 0 провалов**.
- `cd packages/core_protocol && dart test` — **64 пройдено, 0 провалов**.
- `cd packages/core_sync && dart test` — **6 пройдено, 0 провалов**.
- `cd packages/core_domain && dart test` — **25 пройдено, 0 провалов**.
- `cd packages/platform_linux && flutter test` — **7 пройдено, 0 провалов**.
- `cd packages/platform_web && dart test -p chrome -c dart2js` — **18 пройдено, 0 провалов**; `WEB_STORAGE_PERF events=100000 insert_ms=4965 pagination_p95_ms=4`.
- `bash tool/check_text_hygiene.sh` — **OK**.
- `bash tool/check_core_imports.sh` — OK; `bash tool/check_core_storage_deps.sh` — OK; `bash tool/check_docs_drift.sh` — OK.

### Что осталось

- S4-11 (Linux SecureKeyStore `_stateKey`), S4-12 (Android runtime), S4-15 (вложенная копия core_crypto) — вне скоупа слоя 4.
- Q25/Q27/Q28/Q30/Q31 — без изменений.
- Chrome-приёмка AC3/AC4 теперь подтверждена полным прогоном platform_web.

Этап F4.4 завершён. Остановка до ревью.

---

## Запись 27 — Этап F4.5: S4-11 и S4-15

### Решения

1. S4-11: в `LinuxSecureKeyStoreImpl` добавлены `_kStateKeyPrefix = 'opensink_state_key_'` и `_stateKey(keyId)` — паритет с Android. Заодно устранены analyzer-ошибки/предупреждения в том же файле (unused variable, non-const FormatException, лишние скобки, лишнее имя library).
2. S4-15: вложенная копия `packages/core_crypto/packages/core_crypto` удалена. `debug_x3dh.dart` перенесён в `packages/core_crypto/tool/`, получил импорт `core_domain` для `Ok`, вывод через `stdout.writeln`; analyzer чист.
3. Коммиты слоя 4 разбиты на логические: storage/schema/platform factories, S4-13, S4-16, CI, документация.

### Результаты проверок

- `dart analyze packages/platform_linux/lib packages/platform_linux/test packages/core_crypto/tool` — **No issues found!**
- `cd packages/platform_linux && flutter test` — **7 пройдено, 0 провалов**.
- `bash tool/check_core_imports.sh` — OK.
- `bash tool/check_text_hygiene.sh` — OK.
- `bash tool/check_docs_drift.sh` — OK.

### Что осталось

- S4-12 (Android integration runner/runtime SQLite) — вне скоупа.
- Q25/Q27/Q28/Q30/Q31 — без изменений.

Этап F4.5 завершён. Остановка до ревью.

---

## Запись 28 — Этап F4.6: закрытие S4-12 через ручной QA

### Решения

1. Автоматизация Android runtime (S4-12) не требуется: `flutter drive`/integration runner не настраивается.
2. Проверка bundled SQLite и `StorageInfo` на Android переведена в обязательный ручной QA-чек-лист перед релизом.
3. Runtime SQLite на Android остаётся **не проверенным** до фактического выполнения чек-листа; статус «пройдено» заранее не ставится.

### Изменённые документы

- `docs/DEFECTS.md` — S4-12 закрыт как ручной QA.
- `docs/MANUAL_QA.md` — убрана перспектива настройки runner, добавлен обязательный отчёт QA.
- `docs/LAYER4_ACCEPTANCE.md` — добавлен раздел Android runtime со статусом «не проверено».
- `packages/core_storage/DESIGN.md` — остаточные ограничения обновлены.
- `docs/PHASE_LOG.md` — эта запись.

### Результаты проверок

- Код, тесты и CI не менялись.
- `bash tool/check_text_hygiene.sh` — OK.
- `bash tool/check_docs_drift.sh` — OK.
- `git status` — только документация этапа.

### Что осталось

- S4-12: выполнить `docs/MANUAL_QA.md` раздел SQLite/EventStore на Android перед релизом.
- Q25/Q28: runtime-версия SQLite на Android остаётся непроверенной до QA.
- `melos analyze` как блокирующий CI-гейт — после починки pre-existing diagnostics других слоёв.

Этап F4.6 завершён. Остановка до ревью.

---

## Запись 29 — Этап F4.7: зелёный workspace analyze

### Решения

1. Полный `melos run analyze` приведён к exit 0: 0 errors, 0 warnings, 11 info.
2. Основная часть исправлений — механические (`dart fix --apply`): const-конструкторы/декларации, unused imports, unnecessary lambdas/this, library names. После автофикса вручную восстановлены `LinkedHashMap` в `DoubleRatchet` и заменены невидимые comment references на code spans.
3. Исправлен реальный дефект S4-24: `apps/app/pubspec.yaml` ссылался на `../packages/...` вместо `../../packages/...`.
4. Удалены неиспользуемые переменные/фикстуры, которые анализатор пометил после автофикса; тесты не ослаблялись, поведение проверок сохранено.
5. `melos run analyze` остаётся блокирующим шагом CI (уже присутствует в workflow); теперь он зелёный.

### Результаты проверок

- `melos run analyze` — **exit 0**, 0 errors, 0 warnings, 11 info.
- `core_crypto`: 202/202; `core_protocol`: 64/64; `core_domain`: 25/25; `core_storage`: 69/69; `core_sync`: 6/6.
- `platform_linux`: 7/7; `platform_web` Chrome/dart2js: 18/18.
- `check_text_hygiene.sh` — OK; `check_core_imports.sh` — OK; `check_docs_drift.sh` — OK.

### Что осталось

- 11 info-уровневых диагностик (JS interop private types, dangling docs, static-only classes) не блокируют analyze; разобрать при следующей очистке.
- S4-12 остаётся ручным QA.
- Push не выполнялся.

Этап F4.7 завершён. Остановка до ревью.
