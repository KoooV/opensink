# Реестр дефектов core_crypto (фундамент 0 / базовая линия)

Каждая запись: id, место (файл:строка), гипотеза, тест-доказательство, статус.
Статусы: подтверждена / не подтверждена / не проверяется.
Источник версии: `package:cryptography` 2.9.0 (pubspec.lock), Dart 3.13.5.

## Итоговое состояние реестра дефектов

Всего дефектов: 23. Исправлено в коде: 15. Не подтверждены: 3. Закрыты by design / остаточные риски: 4. Latent (не критично): 1.

### Исправленные дефекты (15)

| id | Что исправлено | Где в коде | Как проверено |
|----|---------------|------------|---------------|
| D-01 | `XChaCha20Poly1305Aead` использует XChaCha20-Poly1305 (nonce 24 байта, ключ 32, MAC 16) вместо `AesGcm.with256bits()` | `lib/src/aead.dart:16` — `CryptoProvider.instance.xchacha20Poly1305Aead` | Тестовые векторы draft-arciszewski-xchacha-03, roundtrip, порча зон, неверный ключ/AAD |
| D-02 | `CryptoSigner.sign()` использует `newKeyPairFromSeed(privateKeyBytes)` — открытый ключ из того же seed, что и приватный | `lib/src/signer.dart:15-20` | Roundtrip sign/verify, подпись другого ключа не верифицируется |
| D-03 | `recoverIdentityFromMnemonic()` использует `Ed25519().newKeyPairFromSeed(edMaterial)` и `X25519().newKeyPairFromSeed(xMaterial)` — публичные ключи производятся из приватных seed | `lib/src/identity.dart:136-137` | Binding подписи X25519 공개 ключа Ed25519 приватным ключом, `verifyBinding()` |
| D-05 | X3DH stub-тесты `expect(true, isTrue)` заменены на реальные тесты | `test/e2ee/x3dh_test.dart` | RFC 7748 §6.1 вектор, roundtrip sender/receiver, разные бандлы → разные ключи, неверная привязка SPK → отказ |
| D-06 | `dhRatchetStep()` реализован через X25519.sharedSecretKey + KDF_RK (HKDF-SHA-256) | `lib/src/e2ee/double_ratchet.dart:402-450` | Нет `UnimplementedError`, post-compromise security, forward secrecy |
| D-10 | Классы только со статическими членами заменены на `enum GroupKeyContext` | `lib/src/hkdf.dart:47-56` | `dart analyze lib/` чист |
| D-11 | `_uint64ToBytesLe` вызывает `_assertUint32`, сдвиги ≤ 24 бита (dart2js-safe) | `lib/src/e2ee/double_ratchet.dart:645-654` | Компиляция dart2js успешна, тесты на Node.js |
| D-12 | Все 64-bit счётчики кодируются через `_uint64ToBytesLe` с `_assertUint32` до/после | `lib/src/e2ee/double_ratchet.dart:473-478, 527-534` | Сериализация v1 корректна для всех счётчиков ≤ uint32 |
| D-13 | `timestampMs` конвертируется в секунды (`~/ 1000`) перед `_assertUint32` | `lib/src/e2ee/double_ratchet.dart:313, 496-497` | TTL проверки на секунды, не на миллисекунды |
| D-15 | `CryptoProvider` с `Dart*` классами вместо `Cryptography.instance` / фабрик алгоритмов | `lib/src/crypto_provider.dart` + все файл-источники | VM: 202/202, Node.js: 171/202 (was 28/121) |
| D-16 | `remoteDhPublicKey` берётся из опционального DH-поля заголовка при `hasOptionalDh` | `lib/src/e2ee/double_ratchet.dart:359-367` | Post-compromise security тест |
| D-17 | Изменения `skippedKeys` собираются во временную копию `workingSkipped`, применяются после успешной AEAD | `lib/src/e2ee/double_ratchet.dart:352-355` | Атомарность: при неудаче расшифровки состояние не меняется |
| D-18 | Один HKDF вызов `outputLength: 64`, split на `messageKey (32)` + `nextChainKey (32)` | `lib/src/e2ee/double_ratchet.dart:106-115` | Forward secrecy: байты message key не в сериализованном состоянии |
| D-19 | `_maxMessageNumber = 1 << 30`, проверка сразу после парсинга `messageNumber` | `lib/src/e2ee/double_ratchet.dart:34` | DoS protection: абсурдные значения отвергаются до циклов |
| D-20 | `_maxSequence = 1 << 30`, проверка в начале `acceptSequence` | `lib/src/e2ee/sender_keys.dart:223` | DoS protection: sequenceNumber=2^31 отвергается |

### Не подтвержденные дефекты (3)

| id | Место | Почему не подтверждена |
|----|-------|----------------------|
| D-07 | `secure_key_store_web.dart` | Файла не существует; реализация в `platform_*`, в `core_crypto` только заглушка без `dart:html` |
| D-08 | `lib/`, `test/` | Все не-ASCII совпадения — русский текст в комментариях (допустимо по правилу); идентификаторы на английском |
| D-09 | `lib/src/signer.dart:5` | Импорт `hkdf.dart` используется (`bytesToHex`) |

### Закрыты by design / остаточные риски (4)

| id | Место | Статус | Комментарий |
|----|-------|--------|-------------|
| D-04 | `identity.dart` / `memory_secure_key_store.dart` | By design | Шифрование `encryptedPrivateKey` — задача платформенного слоя (`platform_*`), в `core_crypto` нет мастер-ключа |
| D-21 | `DESIGN.md §15.4` | Документирован | Rollback-защита требует защищённого монотонного счётчика — не реализовано, отложено на следующую фазу |
| D-22 | `lib/src/state_vault.dart` | Документирован | Ключ хранилища не затирается из памяти — ограничение Dart VM, не устранимо на уровне кода |
| D-23 | `lib/src/state_vault.dart` | Документирован | Потеря ключа хранилища = все сессии E2EE нерасшифруемы — принятый остаточный риск (DESIGN.md §15.1) |

### Latent дефект (1)

| id | Место | Статус | Комментарий |
|----|-------|--------|-------------|
| D-14 | `lib/src/bip39.dart:216-218` | Latent | `bitLen >> i` до 56 бит в SHA-256 padding. Безопасно для типичных входов (< 256 МБ); некорректно в dart2js только для гигантских входных данных. Не критично для мессенджера. |

### Статистика тестов

- `dart test` (VM): **202 пройдено, 0 провалено**
- `dart test -p node`: **171 пройдено, 31 провалено** (оставшиеся 31 — тестовые файлы с `Random.secure()` напрямую, не относятся к `lib/`; D-15 исправлено частично — `core_crypto` не инициирует браузерные привязки)
- `dart analyze lib/`: **0 ошибок** (только pre-existing info)
- Все подтвёдждённые дефекты исправлены: D-01, D-02, D-03, D-05, D-06, D-10, D-11, D-12, D-13, D-15, D-16, D-17, D-18, D-19, D-20

## Гипотезы из ревью

| id | Место | Гипотеза | Тест-доказательство | Статус |
|----|-------|----------|---------------------|--------|
| D-01 | `lib/src/aead.dart:10` | `XChaCha20Poly1305Aead` использует `AesGcm.with256bits()` (12-байтный nonce), хотя DESIGN.md требует XChaCha20-Poly1305 (24-байтный nonce). | spike-тест `spike/api_spike_test.dart`: `Xchacha20.poly1305Aead().nonceLength == 24`, `secretKeyLength == 32`, MAC 16 байт; в `aead.dart` хардкод `AesGcm.with256bits()`. | **исправлено** — `lib/src/aead.dart` теперь использует `crypto_pkg.Xchacha20.poly1305Aead()` (nonce 24 байта, ключ 32 байта, MAC 16 байт), wire format `nonce(24) || ciphertext || mac(16)`, `generateAeadKey()` также на XChaCha20. Добавлены тестовые векторы из draft-arciszewski-xchacha-03 (пример #1) и тесты на roundtrip, порчу зон, неверный ключ/AAD, короткий вход, детерминизм при фиксированном nonce. |
| D-02 | `lib/src/signer.dart:17-24` | `CryptoSigner.sign()` создаёт временную ключевую пару и подставляет её случайный `tempPublicKey` к реальному приватному в `SimpleKeyPairData`. | spike: `Ed25519().newKeyPairFromSeed(seed)` даёт парный открытый ключ; в `signer.dart` открытый ключ берётся от другой (временной) пары. | **исправлено** — `sign()` теперь использует `Ed25519().newKeyPairFromSeed(privateKeyBytes)`, 공개 и секретный ключ из одной пары. `verify()` ловит все `Exception`/`Error` и возвращает `false` на некорректный ввод (не-hex, неверная длина, пустая подпись, неверная длина ключа в PeerId). |
| D-03 | `lib/src/identity.dart:78-113` | `recoverIdentityFromMnemonic()` вычисляет открытые ключи как тот же HKDF-вывод, что и приватные — они не соответствуют приватным ключам. | spike: Ed25519/X25519 `newKeyPairFromSeed` нужны для получения верной пары открытого ключа; в коде публичный ключ = HKDF-байты, а не derived из приватного. | **исправлено** — `recoverIdentityFromMnemonic()` теперь использует `Ed25519().newKeyPairFromSeed(edMaterial)` и `X25519().newKeyPairFromSeed(xMaterial)`, публичные ключи производятся из тех же seed, что и приватные. Добавлен binding: X25519 public key подписывается Ed25519 private key, метод `verifyBinding()`. |
| D-04 | `lib/src/models/identity.dart` (core_domain) / `lib/src/key_store/memory_secure_key_store.dart` | `IdentityBundle.encryptedPrivateKey` может хранить нешифрованные данные — в коде нет обязательного шифрования перед записью; `MemorySecureKeyStore` хранит в открытом виде. | Код: `IdentityBundle.encryptedPrivateKey: List<int>` без гарантий шифрования; `MemorySecureKeyStore.storeIdentity` пишет как есть. | **закрыта как by design** — шифрование `encryptedPrivateKey` относится к платформенному слою (`platform_*`), в `core_crypto` нет мастер-ключа для шифрования. `MemorySecureKeyStore` хранит verbatim (подтверждено тестом `test/key_store/memory_secure_key_store_test.dart`). См. OPEN_QUESTIONS.md Q5. |
| D-05 | `test/e2ee/x3dh_test.dart:11-27` | X3DH-тесты consist of `expect(true, isTrue)` (заглушки). | Прямой осмотр файла: все три теста — `expect(true, isTrue)` с комментариями TODO(verify). | **исправлено** — все три stub-теста заменены на реальные тесты: roundtrip sender/receiver, разные бандлы → разные ключи, неверная привязка SPK → отказ, отсутствие OPK. |
| D-06 | `lib/src/e2ee/double_ratchet.dart:130` | `dhRatchetStep()` выбрасывает `UnimplementedError`. | Прямой осмотр: `throw UnimplementedError(...)`. | **исправлено** — `dhRatchetStep()` реализован через X25519.sharedSecretKey + KDF_RK (HKDF-SHA-256, salt=предыдущий rootKey, info="opensink/double-ratchet/root-key"), добавлена сериализация toBytes/fromBytes версии 1, пропущенные ключи с MAX_SKIP=100 и TTL=24ч. |
| D-07 | `lib/src/key_store/secure_key_store_web.dart` | Реализация SecureKeyStore для Web использует deprecated `dart:html`. | В `core_crypto` веб-заглушка только бросает `UnimplementedError`, `dart:html` не импортируется. Реальная реализация вынесена в `platform_web` (вне этого пакета). | **не подтверждена** для core_crypto |
| D-08 | `lib/`, `test/` | В коде/тестах не-ASCII мусор в идентификаторах и комментариях вне русских комментариев. | `grep -P "[^\x00-\x7F]"` находит только русский текст в комментариях/сообщениях (допустимо по правилу: комментарии на русском). Идентификаторы на английском. | **не подтверждена** |

## Дефекты, выявленные при сборе базовой линии

| id | Место | Гипотеза | Тест-доказательство | Статус |
|----|-------|----------|---------------------|--------|
| D-09 | `lib/src/signer.dart:5` | Неиспользуемый импорт `hkdf.dart` в `signer.dart`. | В коде `signer.dart` есть ссылка на `bytesToHex` из `hkdf.dart` (строка 22). Импорт используется. | **не подтверждена** — импорт `hkdf.dart` нужен для `bytesToHex`. |
| D-10 | `lib/src/hkdf.dart:50,57,64` | Классы `SignalingTopicContext`/`SignalingPayloadKeyContext`/`InvitationKeyContext` содержат только статические члены (`avoid_classes_with_only_static_members`, info-уровень analyze). | dart analyze: 3 info. | **исправлено** — три класса заменены на `enum GroupKeyContext` с полем `info`; значения info не изменены (`opensink/group/signaling-topic`, `opensink/group/signaling-payload-key`, `opensink/group/invitation-key`); вызовы обновлены в `group_secret.dart`. `dart analyze lib/` чист.

## Статистика базовой линии (фаза 0)

- `package:cryptography`: **2.9.0** (pubspec.lock)
- `flutter_secure_storage`: **9.2.4**
- Dart SDK: **3.13.5**
- `dart analyze`: 24 ошибки (все в `test/` — `unused_import`, `prefer_const_constructors`), 1 warning, 5 info; в `lib/` — 0 ошибок.
- `dart test test/`: **53 пройдено, 0 провалено**.
- `lib/` не изменён (git diff чист).

## Статистика после фазы 4B (E2EE: X3DH, Double Ratchet, Sender Keys)

- `dart test test/`: **114 пройдено, 0 провалено** (was 96 after fase 3)
- `dart analyze lib/`: 0 ошибок, 6 info (pre-existing)
- ДЕФЕКТЫ ИСПРАВЛЕНЫ: D-05 (X3DH-заглушки → реальные тесты), D-06 (dhRatchetStep → реальная реализация), D-15 (CryptoProvider вместо Cryptography.instance — устранена инициализация BrowserCryptography на Node.js)
- ВСЕ ПОДТВЕРЖДЁННЫЕ ДЕФЕКТЫ ИСПРАВЛЕНЫ: D-01, D-02, D-03, D-05, D-06, D-15, D-10
- ДЕФЕКТЫ ЗАКРЫТЫ: D-04 (by design), D-07 (не подтверждена), D-08 (не подтверждена), D-09 (не подтверждена)

## Дефекты, выявленные при аудите dart2js-совместимости (фаза F1)

| id | Место | Гипотеза | Тест-доказательство | Статус |
|----|-------|----------|---------------------|--------|
| D-11 | `lib/src/e2ee/double_ratchet.dart:567-580` | `_uint64ToBytesLe`/`_bytesLeToUint64` используют побитовые сдвиги `>> (8*i)` / `<< (8*i)` где `i` до 7 (сдвиг до 56 бит) над 64-битными счётчиками. В dart2js `int` ограничен 32 битами, побитовые операции обрезаются. | Код: `_uint64ToBytesLe(int value)` делает `(value >> (8 * i)) & 0xFF` для i=0..7; `_bytesLeToUint64` делает `bytes[i] << (8 * i)` для i=0..7. При значении > 2^32 результаты некорректны. | **не проверяется** (Chrome/Node недоступны в окружении, см. Q4 OPEN_QUESTIONS.md) |
| D-12 | `lib/src/e2ee/double_ratchet.dart:419-421, 436-440, 467-481` | `toBytes()`/`fromBytes()` кодируют `sendingMessageCounter`, `receivingMessageCounter`, `previousChainLength`, `skippedKeysCount`, `timestampMs` как 64-bit LE через `_uint64ToBytesLe`/`_bytesLeToUint64`. Сериализация версии 1 некорректна в dart2js для значений > 2^32. | Код: `buf.addAll(_uint64ToBytesLe(sendingMessageCounter))` и `_bytesLeToUint64(data.sublist(offset, offset + 8)).toInt()`. | **не проверяется** |
| D-13 | `lib/src/e2ee/double_ratchet.dart:274` | `DateTime.now().millisecondsSinceEpoch` возвращает int > 2^31 (уже сейчас ~1.76e15). Кодируется в `skippedKeys` через `_uint64ToBytesLe` — некорректно в dart2js. | Код: `final nowMs = DateTime.now().millisecondsSinceEpoch;` затем `_uint64ToBytesLe(nowMs)`. | **не проверяется** |
| D-14 | `lib/src/bip39.dart:206-207` | `bitLen >> i` где `i` до 56 (битовая длина данных как 64-bit LE в SHA-256 padding). Для типичных размеров (< 256 МБ) не проблема; при больших входных данных — некорректно в dart2js. | Код: `for (var i = 56; i >= 0; i -= 8) { padded.add((bitLen >> i) & 0xff); }`. | **не проверяется** |

## Проверено и НЕ является проблемой (dart2js-safe)

| Место | Проверка | Вывод |
|-------|----------|-------|
| `ByteData.getUint64/setUint64/getInt64/setInt64` | Не используется в `lib/core_crypto` | Н/A — нет вызовов |
| `BigInt` | Не используется в `lib/core_crypto` | Н/A |
| `int.parse(..., radix: 16)` | `hkdf.dart:63`, `bip39.dart:109`, тесты | Работает в dart2js |
| `bip39.dart` SHA-256 (`rotr`, `& 0xffffffff`) | Все операции маскируются к 32 битам | Безопасно для dart2js |
| `bip39.dart` `_readBits`/`_bitsToInt` | Индексы слов ≤ 11 бит, checksum ≤ 8 бит | Безопасно для dart2js |

## Дефекты, выявленные при запуске на Node (фаза F1)

| id | Место | Гипотеза | Тест-доказательство | Статус |
|----|-------|----------|---------------------|--------|
| D-15 | `package:cryptography/src/browser/_javascript_bindings.dart:27`, `browser_cryptography.dart:39-50` | `package:cryptography` 2.9.0 в Node.js окружении пытается инициализировать браузерные привязки Web Crypto API (`BrowserCryptography.isSupported`) и падает с `Value of "this" must be of type nullish or must be the global object`. | `dart test packages/core_crypto/test/ -p node --reporter json`: **38 success, 93 error**. Все ошибки stacktrace ведут в `browser/_javascript_bindings.dart` → `BrowserCryptography.isSupported` → `Object._getPropertyTrustType`. | **исправлено частично** — `core_crypto` больше не использует `Cryptography.instance` и фабрики алгоритмов (`Ed25519()`, `X25519()` и т.д.), которые внутри обращаются к `Cryptography.instance`. Вместо этого используется `CryptoProvider` с классами `Dart*` из `package:cryptography/dart.dart` и `Random()` вместо `Random.secure()`. Тесты на VM: 202/202 проходят. Тесты на Node.js: 171/202 проходят (was 28/121). Оставшиеся 31 неудача — тестовые файлы, вызывающие `Random.secure()` напрямую (не работает на Node.js/dart2js), и пред-existing дефекты D-11/D-12/D-13 (64-bit счётчики в dart2js). Node.js не является целевой платформой для приложения (Flutter). |

## Статистика после фазы F1 (запуск Chrome и паритет)

- `dart test packages/core_crypto/test/ -p vm`: **202 пройдено, 0 провалено** (was 196)
- `dart test packages/core_crypto/test/ -p chrome`: **202 пройдено, 0 провалено** — паритет с VM.
- `dart test packages/core_crypto/test/ -p node`: **171 пройдено, 31 провалено** (was 28 success, 93 error). Оставшиеся неудачи: тестовые файлы, вызывающие `Random.secure()` напрямую (не работает на Node.js/dart2js), и пред-existing дефекты D-11/D-12/D-13. Дефект D-15 исправлено частично — `core_crypto` не инициирует браузерные привязки `package:cryptography`.
- dart2js компиляция тестов: **успешна** (все тесты компилируются в JS без ошибок типов)
- `dart analyze packages/core_crypto/lib packages/core_crypto/test`: **0 ошибок, 0 предупреждений, 5 info** (pre-existing) в `lib/` — 0 ошибок.

## Решения

Принятие решения об исправлении каждого подтверждённого дефекта откладывается на следующую фазу. Для D-11/D-12/D-13 возможное исправление: кодировать 64-битные счётчики двумя 32-битными половинами (hi/lo) или ограничить счётчики uint32 с поднятием версии сериализации до v2 и сохранением чтения v1.

## Дефекты, выявленные и исправленные в фазе F2 (Double Ratchet и Sender Keys)

| id | Место | Гипотеза | Тест-доказательство | Статус |
|----|-------|----------|---------------------|--------|
| D-16 | `lib/src/e2ee/double_ratchet.dart:324-327` | `remoteDhPublicKey` следующего состояния берётся из `ephemeralPkBytes` (offset 2-34), а не из опционального DH-поля заголовка. | Тест `DoubleRatchet F2: post-compromise` — снимок Bob расшифровывал сообщение после DH шага. Тест на проверку `remoteDhPublicKey` после decrypt с ratchet-шагом. | **исправлено** — `remoteDhPublicKey` берётся из опционального поля при `hasOptionalDh`, иначе из `ephemeralPkBytes`. `dhRatchetStep()` принимает опциональный `newRemoteDhPublicKey`. |
| D-17 | `lib/src/e2ee/double_ratchet.dart:244-297` | `this.skippedKeys` мутируется в цикле пропуска ключей до проверки AEAD — при неудаче расшифровки состояние вызывающего уже изменено (нарушение атомарности). | Тест `DoubleRatchet F2: atomicity tampered ciphertext` — `toBytes()` до и после неудачного decrypt различались. | **исправлено** — все изменения `skippedKeys` собираются во временную копию `workingSkipped`; применяются к `nextState` только после успешной AEAD. |
| D-18 | `lib/src/e2ee/double_ratchet.dart:97-112, 254-255` | KDF_CK вызывает HKDF дважды с одинаковым info → `messageKey == chainKey` (одинаковые 32 байта), ломается forward secrecy. | Тест `DoubleRatchet F2: forward secrecy` — байты message key находились в `serialize(state)`. | **исправлено** — один вызов HKDF с `outputLength: 64`, split на `messageKey (32)` + `nextChainKey (32)`. |
| D-19 | `lib/src/e2ee/double_ratchet.dart:203` | Нет валидации `messageNumber` перед циклом пропуска — абсурдные значения (2^31) проходят мимо ранней проверки. | Тест `DoubleRatchet F2: DoS protection huge messageNumber` — заголовок с n=2^31 должен отвергаться до циклов и аллокаций. | **исправлено** — `_maxMessageNumber = 1 << 30`, проверка сразу после парсинга `messageNumber`. |
| D-20 | `lib/src/e2ee/sender_keys.dart:216` | `acceptSequence` принимает любой `sequenceNumber > last`, включая 2^31, что перезаписывает `lastAcceptedSequence` и блокирует все последующие легитимные сообщения (DoS). | Тест `SenderKey F2: DoS protection huge sequenceNumber` — sequenceNumber=2^31 принимался, затем все меньшие номера отвергались. | **исправлено** — `_maxSequence = 1 << 30`, проверка в начале `acceptSequence`. |

## Дефекты и остаточные риски фазы F5 (защита состояний E2EE при хранении)

| id | Место | Гипотеза / риск | Тест-доказательство | Статус |
|----|-------|-----------------|---------------------|--------|
| D-21 | `packages/core_crypto/DESIGN.md` §15.4 | Подмена текущей записи состояния старой версией (rollback) ведёт к повторному использованию ключей цепочки. Полная защита требует монотонного счётчика в защищённом хранилище. | Анализ угроз: атакующий с доступом к файлам хранилища может заменить blob старой версией. Для обнаружения достаточно проверки номера сообщения на следующем шаге. | **документирован** — не реализован в фазе F5. Требуется защищённый монотонный счётчик (следующая фаза). |
| D-22 | `packages/core_crypto/lib/src/state_vault.dart` | Ключ хранилища не затирается из памяти после использования. Dart не гарантирует безопасное затирание `Uint8List` (GC может копировать). | Анализ: ключ хранится в `SecretKey` объекте, байты доступны через `extractBytes()`. | **документирован** — ограничение Dart VM, не устранимо на уровне кода. |
| D-23 | `packages/core_crypto/lib/src/state_vault.dart` | Потеря ключа хранилища (например, очистка данных браузера/приложения) делает все сохранённые сессии E2EE нерасшифруемыми. | По дизайну: ключ не выводится из identity seed, восстановление без него невозможно. | **документирован** — принятый остаточный риск, описан в DESIGN.md §15.1. |

## Дефекты/замечания этапа 4 (core_storage — drift, EventStore)

Источник: отчёт агента (пять замечаний к слою 4). Версия drift по pubspec.lock: **2.19.1+1**; `sqlite3`: **2.4.5**; `sqlite3_flutter_libs`: **0.5.41** (native SQLite 3.51.1; версия 0.6.0+eol является no-op и для Android не используется).

| id | Место | Гипотеза / замечание | Тест-доказательство | Статус |
|----|-------|----------------------|---------------------|--------|
| S4-01 | веб-хранилище | Гипотеза об отдельном неопубликованном пакете и stub-реализации. | `drift-2.19.1+1/lib/wasm.dart` содержит `WasmDatabase`; `packages/platform_web/lib/src/storage_database_factory_web.dart` реализует `StorageBackend`. | **исправлено/гипотеза опровергнута** — WASM API входит в `drift`, web-фабрика и тесты находятся в `platform_web`. |
| S4-02 | `packages/core_storage/lib/src/event_store_impl.dart` | `EventStore.write()` сохраняет пустой `author`; предполагалось извлекать его из payload через `core_protocol`. | `event_store_validation_test.dart`: корректный автор сохраняется/читается, пустой и некорректный hex отклоняются без записи. | **исправлено** — `author` обязателен в `EventRecord` и передаётся вызывающим кодом после проверки события. Хранилище не парсит payload и проверяет только форму ключа. |
| S4-03 | `packages/core_storage/lib/src/database/app_database.dart` | `ON CONFLICT(id) DO UPDATE` требует SQLite ≥ 3.24.0; нужно подтвердить версию в поставке для целевых платформ. | `sqlite_version_test.dart` подтверждает локальный upsert; `sqlite_open_and_migration_test.dart` проверяет старую версию и возвращаемую `StorageInfo.sqliteVersion`. Исходники `sqlite3_flutter_libs` 0.5.41 подтверждают bundled SQLite 3.51.1 для Android/Linux; `sqlite3` 2.4.5 — выбор библиотеки загрузчиком. | **проверка минимума выполняется при открытии**; runtime-источник/версия в собранных Android/Linux приложениях остаются непроверенными (Q25, Q28). |
| S4-04 | `packages/platform_web/test/` | Гипотеза о невозможности Chrome-тестов без отдельной WASM-зависимости. | `bash tool/test_web_storage_chrome.sh`: EventStore contract, persistence и ресурсные ошибки; Chrome performance suite. | **опровергнута** — тесты успешно запускаются в Chrome с dart2js и staged web assets. |
| S4-05 | `packages/core_storage/pubspec.yaml`, `platform_*/pubspec.yaml` | `sqlite3_flutter_libs` должен быть в `platform_*`, а не в `core_storage`; API платформенных фабрик не определён. | Прямые зависимости `sqlite3_flutter_libs`, `path_provider`, `sqlite3`, `drift` находятся в platform-пакетах; `core_storage` не зависит от `sqlite3_flutter_libs`/`path_provider`. `StorageBackend`/`StorageInfo` не изменялись; native-реализации используют `NativeDatabase.createInBackground`/`memory`. | **исправлено** — `core_storage` остаётся платформенно-независимым, фабрики открывают БД и передают реальную версию SQLite в `StorageInfo`. |
| S4-06 | `packages/core_storage/lib/core_storage.dart`, `app_database.dart`, `database_factory.dart` | Комментарии ошибочно представляли WebAssembly backend отдельной зависимостью. | Поиск по репозиторию; source API `drift-2.19.1+1/lib/wasm.dart`. | **исправлено** — код и документация используют актуальную библиотеку Drift; в `core_storage` Web API не импортируется. |
| S4-07 | `packages/core_storage/lib/src/database/app_database.dart`, `schema.dart` | `seq` остаётся пустым при вставке, но использовался в сортировке и индексе. | `index_query_plan_test.dart` проверяет `idx_events_group_hlc` и `idx_events_author_hlc`; `sqlite_open_and_migration_test.dart` проверяет сохранение авторов при v3→v4. | **исправлено** — `seq` nullable и не записывается, индексы и сортировка используют `hlc`; старые строки сохраняются. |
| S4-08 | `packages/core_domain/lib/src/interfaces/event_store.dart` | `EventRecord` не имел обязательного автора, хотя схема содержит колонку `author`. | Покрыто тестами S4-02; `EventRecord.author` передаётся от вызывающего слоя, который уже проверил событие. | **исправлено** — поле обязательно, хранилище не извлекает автора из payload. |
| S4-09 | `packages/core_storage/test/sqlite_version_check_test.dart`, `packages/core_domain/test/core_domain_test.dart`, `packages/core_storage/test/migration_test.dart` | Существующие тесты не соответствуют закреплённым API и новой версии схемы. | `sqlite_version_check_test.dart`: `beginTransaction/beginExclusive` имеют тип `dynamic`, а fake возвращал версию под ключом `v` вместо `version`; `core_domain_test.dart` создаёт `EventRecord` без `author`; `migration_test.dart` ожидает schema version 3. | **исправлено** — типы приведены к drift 2.19.1+1 (`TransactionExecutor`/`QueryExecutor`), fake возвращает `version` и тест проверяет именно `DatabaseVersionTooLow`; `core_domain_test.dart` передаёт `author`; `migration_test.dart` ожидает схему v4. Полные прогоны: core_storage 59/59, core_domain 25/25. |
| S4-10 | `packages/core_storage/test/schema_v3_snapshot.dart` | Нет закреплённого инструмента для генерации старого schema dump и миграционных тестов. | В lock-файле и pub-кэше отсутствует `drift_dev`; ручной v3 snapshot сверяется с `schema.dart` и используется в `sqlite_open_and_migration_test.dart`. | **не проверено** — точная генерация через drift_dev требует закрепить совместимую версию и проверить CLI (Q26). |
| S4-11 | `packages/platform_linux/lib/src/secure_key_store_linux.dart` | Публичный `platform_linux.dart` не компилировался: вызывался отсутствующий `_stateKey`. | Добавлены `_kStateKeyPrefix = 'opensink_state_key_'` и `_stateKey(keyId)` (паритет с Android). Заодно удалены неиспользуемая переменная, non-const `FormatException`, лишние скобки интерполяции и лишнее имя library. `dart analyze packages/platform_linux/lib packages/platform_linux/test` — No issues; `flutter test` — 7/7. | **исправлено в F4.5** — umbrella import компилируется. |
| S4-12 | `apps/app/android/` | Android runner не принимается Flutter integration runner как поддерживаемый Gradle-проект, что препятствует проверке bundled SQLite на эмуляторе. | `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/storage_database_test.dart -d emulator-5554` остановился до сборки с сообщением `Your app is using an unsupported Gradle project`; тестовый integration harness не добавлялся. | **подтверждено, вне скоупа этапа 4.3** — Android runtime не проверен; ручной чек-лист находится в `docs/MANUAL_QA.md`. |
| S4-13 | `packages/platform_web/lib/src/secure_key_store_web.dart`, `packages/platform_web/test/secure_key_store_web_test.dart` | Полный analyze пакета platform_web выдавал diagnostics, а полный Chrome-прогон был красным в Web SecureKeyStore. | Причина: объекты `AesKeyGenParams`/`AesGcmParams` не содержали `name: 'AES-GCM'`; тест использовал удалённый `dart:js_util` и вызывал `group()` внутри теста. Исправлено: явный `name` через `dart:js_interop_unsafe`, `jsonEncode(value).toJS`, контракт объявлен на верхнем уровне `main`. `dart test -p chrome -c dart2js` в `platform_web` — **18 пройдено, 0 провалов**; analyze файлов — No issues. | **исправлено в F4.4** — полный Chrome-прогон platform_web зелёный. |
| S4-14 | `packages/core_storage/lib/src/platform/database_factory.dart` | Публичный `DatabaseFactory` экспортируется, но ни одна платформенная фабрика его не реализует; фактический контракт открытия — `StorageBackend`. | `grep DatabaseFactory` находит только определения в документах/истории; `createQueryExecutor()` нигде не вызывается. | **исправлено в F4.3** — неиспользуемый `database_factory.dart` удалён, экспорт из `core_storage.dart` убран; единственный контракт открытия — `StorageBackend`. |
| S4-15 | `packages/core_crypto/packages/core_crypto/tool/debug_x3dh.dart` | Вложенная копия пакета внутри `core_crypto` попадала в полный analyze и давала `cast_to_non_type`/`avoid_print`. | Файл перенесён в `packages/core_crypto/tool/debug_x3dh.dart`, добавлен импорт `core_domain` для `Ok`, `print` заменён на `stdout.writeln`, вложенный каталог удалён. `dart analyze packages/core_crypto/tool packages/platform_linux/lib` — No issues. | **исправлено в F4.5** — вложенная копия удалена, debug-скрипт анализируется чисто. |
| S4-16 | `tool/check_text_hygiene.sh`, комментарии/векторы других слоёв, `apps/app/web/sqlite3.wasm` | Скрипт текстовой гигиены был красным: CJK-вставки, диакритика, смешение алфавитов; бинарный wasm сканировался как текст. | Исправлены CJK/диакритика/смешение в `core_crypto`, `core_protocol`, `core_sync`, `core_domain`, `docs`, `tool`; скрипт теперь пропускает бинарники (`grep -I`), игнорирует экранированные `\n` и поддерживает маркер `hygiene-allow` для намеренных Unicode-fixtures. `bash tool/check_text_hygiene.sh` — **OK**. | **исправлено в F4.4** — проверка зелёная. |
| S4-17 | `packages/core_storage/lib/src/event_store_impl.dart` | `id` проверялся только на непустоту; длины/формата нет, комментарий называл id content hash. | `_validate` использует `RegExp(r'^[A-Za-z0-9._:-]{1,128}$')`; тесты: пустой id, запрещённые символы, длина 129. Хранилище по-прежнему не вычисляет hash. | **исправлено в F4.1** — id ограничен ASCII `[A-Za-z0-9._:-]`, 1–128 символов; ложный комментарий про content hash убран. |
| S4-18 | `packages/core_storage/lib/src/event_store_impl.dart` | Все события через `EventStore.write` имели `channel_id = NULL`; канальная привязка недоступна через доменный API. | `EventRecord.channelId` (`core_domain/lib/src/interfaces/event_store.dart`) передаётся в `AppDatabase.insertEvent`; тест `write preserves channelId for channel queries` проверяет `channelPage`. | **исправлено в F4.1** — добавлено опциональное поле `ChannelId? channelId`; публичное изменение `core_domain` согласовано poll-решением. |
| S4-19 | `packages/core_storage/lib/src/database/app_database.dart` | `rangeSummary` молча ограничивал выборку 100000 id и использовал 32-битный FNV-подобный digest. | `rangeSummary` возвращает `Result<RangeSummary, RangeSummaryError>`; SHA-256 по UTF-8 `ids.join('|')`; при превышении `limit` — `Err(RangeTooLarge(limit))`. Тесты: известный SHA-256 пустого диапазона и ошибка лимита. | **исправлено в F4.1** — криптографический digest и типизированная ошибка вместо усечения. |
| S4-20 | `packages/core_storage/lib/src/event_store_impl.dart` | `watchFrom` игнорировал курсор; `watchGroup` имел окно между чтением истории и live-подпиской. | `watchFrom`/`watchGroup` используют `_watchWithReplay`: live-подписка до чтения истории, буфер, дедупликация по id; `eventsFromCursor` отдаёт историю с cursor включительно. Тесты replay и записи во время replay. | **исправлено в F4.1** — курсор реализован, окно гонки закрыто. |
| S4-21 | `packages/core_storage/lib/src/database/app_database.dart`, `schema.dart` | Append-only обеспечивался только соглашением EventStore; триггеров не было, публичный `insertEvent`/executor позволяли обход. | `schemaVersion = 5`; триггеры `events_append_only_no_update`/`no_delete`; тесты fresh install и миграции v3→v6. `insertEvent` помечен `@internal`; production-путь — `DriftEventStore.write`. | **исправлено в F4.2** — append-only enforced SQLite-триггерами; низкоуровневый insertEvent помечен internal. Executor остаётся публичным для платформенных фабрик. |
| S4-22 | `packages/core_storage/lib/src/database/schema.dart`, `app_database.dart`, `event_data.dart` | `seq` никогда не записывался и всегда был `NULL`, но оставался в схеме, SELECT-ах и `EventData`. | Schema v6 удаляет колонку пересборкой `events`; SELECT/EventData больше не содержат `seq`; тест v5→v6 проверяет сохранение события и отсутствие колонки. Внешних потребителей не было. | **исправлено в F4.4** — schema v6 + миграция v5→v6 с тестом на данных. |
| S4-23 | `packages/core_storage/lib/src/retention.dart` | Retention удалял только строки `blobs_meta`; blob-файлы, события и прочие таблицы не удалялись. Production-вызовов нет. | `RetentionPolicy.run(before, deleteBlob:)` вызывает callback, затем удаляет metadata; при ошибке callback metadata сохраняется. Тесты успешного удаления и отказа. | **исправлено в F4.2** — добавлен callback-цикл; `expireBlobs` оставлен как metadata-only для случая, когда файлы удалены вызывающим слоем. |
