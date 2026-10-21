# Реестр дефектов core_crypto (фундамент 0 / базовая линия)

Каждая запись: id, место (файл:строка), гипотеза, тест-доказательство, статус.
Статусы: подтверждена / не подтверждена / не проверяется.
Источник версии: `package:cryptography` 2.9.0 (pubspec.lock), Dart 3.13.5.

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
- ДЕФЕКТЫ ИСПРАВЛЕНЫ: D-05 (X3DH-заглушки → реальные тесты), D-06 (dhRatchetStep → реальная реализация)
- ВСЕ ПОДТВЕРЖДЁННЫЕ ДЕФЕКТЫ ИСПРАВЛЕНЫ: D-01, D-02, D-03, D-05, D-06, D-10
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
| D-15 | `package:cryptography/src/browser/_javascript_bindings.dart:27`, `browser_cryptography.dart:39-50` | `package:cryptography` 2.9.0 в Node.js окружении пытается инициализировать браузерные привязки Web Crypto API (`BrowserCryptography.isSupported`) и падает с `Value of "this" must be of type nullish or must be the global object`. | `dart test packages/core_crypto/test/ -p node --reporter json`: **38 success, 93 error**. Все ошибки stacktrace ведут в `browser/_javascript_bindings.dart` → `BrowserCryptography.isSupported` → `Object._getPropertyTrustType`. | **подтверждена** |

## Статистика после фазы F1 (запуск Chrome и паритет)

- `dart test packages/core_crypto/test/ -p vm`: **120 пройдено, 0 провалено**
- `dart test packages/core_crypto/test/ -p chrome`: **не проверено** — Chrome есть (`/usr/bin/google-chrome-stable`), `CHROME_EXECUTABLE` задан, но тестовый раннер `package:test` не может отдать `dart.js` с MIME-типом `application/javascript` (отдаёт `text/plain`), Chrome блокирует выполнение (strict MIME checking). Инфраструктурная проблема (Q4 OPEN_QUESTIONS.md), не код.
- `dart test packages/core_crypto/test/ -p node`: **подтверждённый дефект D-15** — Node.js установлен, тесты компилируются через dart2js, но 93 из 121 тестов падают с ошибкой инициализации браузерных привязок `package:cryptography`. 38 тестов прошли (те, что не зависят от глобальной криптографии браузера).
- dart2js компиляция тестов: **успешна** (все тесты компилируются в JS без ошибок типов)
- `dart analyze packages/core_crypto/lib packages/core_crypto/test`: **0 ошибок, 0 предупреждений, 5 info** (pre-existing)

## Решения

Принятие решения об исправлении каждого подтверждённого дефекта откладывается на следующую фазу. Для D-11/D-12/D-13 возможное исправление: кодировать 64-битные счётчики двумя 32-битными половинами (hi/lo) или ограничить счётчики uint32 с поднятием версии сериализации до v2 и сохранением чтения v1.

## Дефекты, выявленные и исправленные в фазе F2 (Double Ratchet и Sender Keys)

| id | Место | Гипотеза | Тест-доказательство | Статус |
|----|-------|----------|---------------------|--------|
| D-16 | `lib/src/e2ee/double_ratchet.dart:324-327` | `remoteDhPublicKey` следующего состояния берётся из `ephemeralPkBytes` (offset 2-34), а не из опционального DH-поля заголовка. | Тест `DoubleRatchet F2: post-compromise` — снимок Bob расшифровывал сообщение после DH шага. Тест на проверку `remoteDhPublicKey` после decrypt с ratchet-шагом. | **исправлено** — `remoteDhPublicKey` берётся из опционального поля при `hasOptionalDh`, иначе из `ephemeralPkBytes`. `dhRatchetStep()` принимает опциональный `newRemoteDhPublicKey`. |
| D-17 | `lib/src/e2ee/double_ratchet.dart:244-297` | `this.skippedKeys` мутируется в цикле пропуска ключей до проверки AEAD — при неудаче расшифровки состояние вызывающего уже изменено (нарушение атомарности). | Тест `DoubleRatchet F2: atomicity tampered ciphertext` — `toBytes()` до и после неудачного decrypt различались. | **исправлено** — все изменения `skippedKeys` собираются во временную копию `workingSkipped`; применяются к `nextState` только после успешной AEAD. |
| D-18 | `lib/src/e2ee/double_ratchet.dart:97-112, 254-255` | KDF_CK вызывает HKDF дважды с одинаковым info → `messageKey == chainKey` (одинаковые 32 байта), ломается forward secrecy. | Тест `DoubleRatchet F2: forward secrecy` — байты message key находились в `serialize(state)`. | **исправлено** — один вызов HKDF с `outputLength: 64`, split на `messageKey (32)` + `nextChainKey (32)`. |
| D-19 | `lib/src/e2ee/double_ratchet.dart:203` | Нет валидации `messageNumber` перед циклом пропуска — absurdные значения (2^31) проходят мимо ранней проверки. | Тест `DoubleRatchet F2: DoS protection huge messageNumber` — заголовок с n=2^31 должен отвергаться до циклов и аллокаций. | **исправлено** — `_maxMessageNumber = 1 << 30`, проверка сразу после парсинга `messageNumber`. |
| D-20 | `lib/src/e2ee/sender_keys.dart:216` | `acceptSequence` принимает любой `sequenceNumber > last`, включая 2^31, что перезаписывает `lastAcceptedSequence` и блокирует все последующие легитимные сообщения (DoS). | Тест `SenderKey F2: DoS protection huge sequenceNumber` — sequenceNumber=2^31 принимался, затем все меньшие номера отвергались. | **исправлено** — `_maxSequence = 1 << 30`, проверка в начале `acceptSequence`. |

## Дефекты и остаточные риски фазы F5 (защита состояний E2EE при хранении)

| id | Место | Гипотеза / риск | Тест-доказательство | Статус |
|----|-------|-----------------|---------------------|--------|
| D-21 | `packages/core_crypto/DESIGN.md` §15.4 | Подмена текущей записи состояния старой версией (rollback) ведёт к повторному использованию ключей цепочки. Полная защита требует монотонного счётчика в защищённом хранилище. | Анализ угроз: атакующий с доступом к файлам хранилища может заменить blob старой версией. Для обнаружения достаточно проверки номера сообщения на следующем шаге. | **документирован** — не реализован в фазе F5. Требуется защищённый монотонный счётчик (следующая фаза). |
| D-22 | `packages/core_crypto/lib/src/state_vault.dart` | Ключ хранилища не затирается из памяти после использования. Dart не гарантирует безопасное затирание `Uint8List` (GC может копировать). | Анализ: ключ хранится в `SecretKey` объекте, байты доступны через `extractBytes()`. | **документирован** — ограничение Dart VM, не устранимо на уровне кода. |
| D-23 | `packages/core_crypto/lib/src/state_vault.dart` | Потеря ключа хранилища (например, очистка данных браузера/приложения) делает все сохранённые сессии E2EE нерасшифруемыми. | По дизайну: ключ не выводится из identity seed, восстановление без него невозможно. | **документирован** — принятый остаточный риск, описан в DESIGN.md §15.1. | |
