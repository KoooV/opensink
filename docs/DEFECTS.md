# Реестр дефектов core_crypto (фундамент 0 / базовая линия)

Каждая запись: id, место (файл:строка), гипотеза, тест-доказательство, статус.
Статусы: подтверждена / не подтверждена / не проверяется.
Источник версии: `package:cryptography` 2.9.0 (pubspec.lock), Dart 3.13.5.

## Гипотезы из ревью

| id | Место | Гипотеза | Тест-доказательство | Статус |
|----|-------|----------|---------------------|--------|
| D-01 | `lib/src/aead.dart:10` | `XChaCha20Poly1305Aead` использует `AesGcm.with256bits()` (12-байтный nonce), хотя DESIGN.md требует XChaCha20-Poly1305 (24-байтный nonce). | spike-тест `spike/api_spike_test.dart`: `Xchacha20.poly1305Aead().nonceLength == 24`, `secretKeyLength == 32`, MAC 16 байт; в `aead.dart` хардкод `AesGcm.with256bits()`. | **подтверждена** |
| D-02 | `lib/src/signer.dart:17-24` | `CryptoSigner.sign()` создаёт временную ключевую пару и подставляет её случайный `tempPublicKey` к реальному приватному в `SimpleKeyPairData`. | spike: `Ed25519().newKeyPairFromSeed(seed)` даёт парный открытый ключ; в `signer.dart` открытый ключ берётся от другой (временной) пары. | **подтверждена** |
| D-03 | `lib/src/identity.dart:78-113` | `recoverIdentityFromMnemonic()` вычисляет открытые ключи как тот же HKDF-вывод, что и приватные — они не соответствуют приватным ключам. | spike: Ed25519/X25519 `newKeyPairFromSeed` нужны для получения верной пары открытого ключа; в коде публичный ключ = HKDF-байты, а неderived из приватного. | **подтверждена** |
| D-04 | `lib/src/models/identity.dart` (core_domain) / `lib/src/key_store/memory_secure_key_store.dart` | `IdentityBundle.encryptedPrivateKey` может хранить нешифрованные данные — в коде нет обязательного шифрования перед записью; `MemorySecureKeyStore` хранит в открытом виде. | Код: `IdentityBundle.encryptedPrivateKey: List<int>` без гарантий шифрования; `MemorySecureKeyStore.storeIdentity` пишет как есть. | **подтверждена** (разрыв в гарантии) |
| D-05 | `test/e2ee/x3dh_test.dart:11-27` | X3DH-тесты consist of `expect(true, isTrue)` (заглушки). | Прямой осмотр файла: все три теста — `expect(true, isTrue)` с комментариями TODO(verify). | **подтверждена** |
| D-06 | `lib/src/e2ee/double_ratchet.dart:130` | `dhRatchetStep()` выбрасывает `UnimplementedError`. | Прямой осмотр: `throw UnimplementedError(...)`. | **подтверждена** |
| D-07 | `lib/src/key_store/secure_key_store_web.dart` | Реализация SecureKeyStore для Web использует deprecated `dart:html`. | В `core_crypto` веб-заглушка только бросает `UnimplementedError`, `dart:html` не импортируется. Реальная реализация вынесена в `platform_web` (вне этого пакета). | **не подтверждена** для core_crypto |
| D-08 | `lib/`, `test/` | В коде/тестах не-ASCII мусор в идентификаторах и комментариях вне русских комментариев. | `grep -P "[^\x00-\x7F]"` находит только русский текст в комментариях/сообщениях (допустимо по правилу: комментарии на русском). Идентификаторы на английском. | **не подтверждена** |

## Дефекты, выявленные при сборе базовой линии

| id | Место | Гипотеза | Тест-доказательство | Статус |
|----|-------|----------|---------------------|--------|
| D-09 | `lib/src/signer.dart:5` | Неиспользуемый импорт `hkdf.dart` в `signer.dart`. | В коде `signer.dart` нет ссылок на символы из `hkdf.dart`. | **подтверждена** (минорно) |
| D-10 | `lib/src/hkdf.dart:50,57,64` | Классы `SignalingTopicContext`/`SignalingPayloadKeyContext`/`InvitationKeyContext` содержат только статические члены (`avoid_classes_with_only_static_members`, info-уровень analyze). | dart analyze: 3 info. | **подтверждена** (стиль, минорно) |

## Статистика базовой линии (фаза 0)

- `package:cryptography`: **2.9.0** (pubspec.lock)
- `flutter_secure_storage`: **9.2.4**
- Dart SDK: **3.13.5**
- `dart analyze`: 24 ошибки (все в `test/` — `unused_import`, `prefer_const_constructors`), 1 warning, 5 info; в `lib/` — 0 ошибок.
- `dart test test/`: **53 пройдено, 0 провалено**.
- `lib/` не изменён (git diff чист).

## Решения

Принятие решения об исправлении каждого подтверждённого дефекта откладывается на следующую фазу на основе таблицы «Verified API» в DESIGN.md.
