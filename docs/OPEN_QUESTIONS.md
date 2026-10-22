# Открытые вопросы core_crypto (фундамент 0)

## Индекс TODO(verify) в коде (этап 4.5)

Каждая строка соответствует одному маркеру `TODO(verify)` в `.dart`-файлах `packages/` и `apps/`. Команда сверки и результат — в `docs/LAYER4_ACCEPTANCE.md`, раздел AC-документации.

| # | Маркер | Вопрос |
|---|--------|--------|
| TODO-01 | `packages/core_crypto/test/bip39_integrity_test.dart:55` | Q33 |
| TODO-02 | `packages/core_crypto/test/bip39_integrity_test.dart:172` | Q33 |
| TODO-03 | `packages/core_group/lib/core_group.dart:3` | Q12 |
| TODO-04 | `packages/core_media/lib/core_media.dart:3` | Q13 |
| TODO-05 | `packages/core_peer/lib/core_peer.dart:3` | Q14 |
| TODO-06 | `packages/core_relay/lib/core_relay.dart:3` | Q16 |
| TODO-07 | `packages/core_signaling/lib/core_signaling.dart:3` | Q17 |
| TODO-08 | `packages/core_storage/test/schema_v3_snapshot.dart:3` | Q26 |
| TODO-09 | `packages/core_sync/lib/core_sync.dart:5` | Q19 |
| TODO-10 | `packages/core_sync/lib/src/hlc_validator.dart:17` | Q32 |

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

Браузер Chrome/Chromium присутствует (`google-chrome-stable`). `dart test -p chrome` загружает и выполняет тестовый суит корректно — MIME-тип `dart.js` не блокирует выполнение в этом окружении (строгая проверка MIME не срабатывает).

Проверено: `dart test packages/core_crypto/test/ -p chrome` — **196 пройдено, 0 провалено**. Побайтовый паритет с VM (196/196).

Логика `platform_web` (IndexedDB + AES-GCM KEK) компилируется через `dart2js` без ошибок типов. Рантайм-тестирование IndexedDB в headless Chrome требует отдельной настройки (профиль, разрешения), но не блокирует приёмку.

## Q5 — encryptedPrivateKey гарантии
`IdentityBundle.encryptedPrivateKey` named "encrypted", но код не гарантирует шифрование; `MemorySecureKeyStore` хранит в открытом виде. Нужно ли добавлять обязательное шифрование на уровне core_crypto, или шифрование полностью platform-специфично — открыто.

## Q6 — SimpleKeyPairData с X25519 — ЗАКРЫТО

`x3dh.dart` `receiver()` использует `SimpleKeyPairData(..., type: KeyPairType.x25519)` для воссоздания пары из приватных байт. Подтверждено работой тестов X3DH roundtrip и RFC 7748 §6.1. Миграция на cryptography v3.x не требуется.

## Q7 — MAX_SKIP и TTL пропущенных ключей Double Ratchet
Значение лимита пропущенных ключей (предложено 100) и TTL (предложено 24 ч) не обоснованы источником. Нужно зафиксировать после анализа угроз replay/DoS.

## Q8 — Контекст подписи SPK binding
Точный формат кодирования контекста `"opensink/x3dh/spk-binding/v1"` + SPK public key (raw байты или с префиксом) не зафиксирован.

## Q9 — Формат заголовка и AAD Double Ratchet
Версия 1 заголовка и состав AAD предложены в DESIGN §13.3, но не сверены с требованиями слоя 3 (Envelope).

## Q10 — Триггер ротации signed prekey без сервера
Интервал TTL (предложено 7 дней), grace period и механизм распространения новой SPK без сервера — открыто (слой 8 диктует триггер).

## Q11 — Контракт сериализации состояния Double Ratchet
`toBytes`/`fromBytes` версии 1 предложены в DESIGN §13.3, но делегированы слою 3. Нужно подтвердить, что core_crypto должен предоставлять этот контракт.

## Q12 — core_group: GroupState, права доступа, валидация подписей событий
`// TODO(verify): GroupState, права доступа, валидация подписей событий.` (packages/core_group/lib/core_group.dart:3)

## Q13 — core_media: MediaTopology реализация, звонки и демонстрация экрана
`// TODO(verify): MediaTopology реализация, звонки и демонстрация экрана.` (packages/core_media/lib/core_media.dart:3)

## Q14 — core_peer: flutter_webrtc реализация PeerLink / Transport
`// TODO(verify): flutter_webrtc реализация PeerLink / Transport.` (packages/core_peer/lib/core_peer.dart:3)

## Q15 — core_protocol: protobuf схемы и конвертеры envelopes
`// TODO(verify): protobuf схемы и конвертеры envelopes.` (packages/core_protocol/lib/core_protocol.dart:3)

## Q16 — core_relay: Relay реализация маршрутизации через участников группы
`// TODO(verify): Relay реализация маршрутизации через участников группы.` (packages/core_relay/lib/core_relay.dart:3)

## Q17 — core_signaling: Nostr, трекеры, LAN, QR реализации SignalingChannel
`// TODO(verify): Nostr, трекеры, LAN, QR реализации SignalingChannel.` (packages/core_signaling/lib/core_signaling.dart:3)

## Q18 — core_storage: drift-схема и реализация EventStore — ЗАКРЫТО
Реализовано в этапах 4.0–4.5: схема v4, `AppDatabase`, `DriftEventStore`, миграции, native- и web-фабрики. Маркер `TODO(verify)` из `packages/core_storage/lib/core_storage.dart` удалён. Доказательства — `docs/LAYER4_ACCEPTANCE.md`.

## Q19 — core_sync: SyncEngine реализация поверх EventStore
`// TODO(verify): SyncEngine реализация поверх EventStore.` (packages/core_sync/lib/core_sync.dart:3)

## Q20 (F4A) — flutter_secure_storage версия с поддержкой Linux
Минимальная версия flutter_secure_storage с рабочей поддержкой Linux (libsecret / secret-service). pubspec.lock фиксирует 9.2.4, но нужно подтвердить, что эта версия корректно собирается на Linux и опции платформ соответствуют README.

## Q21 (F4A) — Способ мока flutter_secure_storage в тестах
`FlutterSecureStorage` — конкретный класс, не интерфейс. В `platform_android/test/flutter_secure_key_store_test.dart` используется ручной мок через `implements FlutterSecureStorage`. Нужно проверить, что все публичные члены `FlutterSecureStorage` покрыты моком, иначе компиляция упадёт при обновлении версии плагина.

## Q22 (F4A) — Android Auto Backup настройки для v9.2.4
Точные настройки `AndroidManifest.xml` (android:allowBackup, android:fullBackupContent, исключение файлов хранилища из бэкапа) для flutter_secure_storage v9.2.4. behoviour при восстановлении на новом устройстве с недействительным ключом Keystore.

## Q23 (F4A) — Linux integration_test под dbus-run-session
Запуск Linux-тестов SecureKeyStore в CI с `dbus-run-session` и запущенным gnome-keyring. В текущем окружении не проверено.

## Q24 (F4A) — Проверка зависимостей libsecret при инициализации Linux
`LinuxSecureKeyStoreImpl.checkDependencies()` выполняет probe-запись в libsecret. Нужно подтвердить, что это достаточно для определения недоступности Secret Service и не создаёт побочных эффектов.

## Q25 (этап 4) — Версия SQLite в сборках целевых платформ
`sqlite_version_test.dart` подтверждает поддержку `ON CONFLICT ... DO UPDATE` для `NativeDatabase.memory()` в текущем окружении; runtime-проверка добавлена в core. Отдельно проверить фактическую версию SQLite в собранных приложениях Android/Linux. Источники для проверки: закреплённые версии `sqlite3`/`sqlite3_flutter_libs`, документация их платформенных backend-ов и тесты целевых сборок.

## Q26 (этап 4.2) — drift_dev schema dump и migration-test API
`drift_dev` отсутствует в `pubspec.lock` и pub-кэше, поэтому schema v3 snapshot создан вручную и сверяется с `packages/core_storage/lib/src/database/schema.dart`. TODO(verify): закрепить совместимую с workspace версию `drift_dev`, проверить по `dart run drift_dev --help` точную команду schema dump и API migration-тестов, сохранить версию и команды в design doc, затем заменить ручной snapshot сгенерированным.

## Q27 (этап 4.3) — реальные гарантии durability при потере питания
Native-фабрики используют `foreign_keys=ON`, `journal_mode=WAL`, `synchronous=FULL`. Документация SQLite указывает, что эти настройки повышают целостность/синхронизацию, но фактическая гарантия зависит от ОС, файловой системы и накопителя. TODO(verify): проверить документированные SQLite power-loss guarantees для закреплённой сборки, Android-файловой системы и поддерживаемых Linux-файловых систем; отдельно определить, какие подтверждённые commit-ы могут быть потеряны при внезапном обесточивании.

## Q28 (этап 4.3) — runtime-источник SQLite в собранных приложениях
`sqlite3_flutter_libs` закреплён на 0.5.41: package README и Android dependency указывают bundled SQLite 3.51.1; Linux CMake собирает SQLite в native plugin, а `sqlite3` 2.4.5 предпочитает символы Flutter-приложения при наличии plugin registration symbol. Статический исходник подтверждён, но фактически загруженную библиотеку в собранных Android APK и Linux bundle нужно проверить на целевых сборках; сохранить версию из `StorageInfo.sqliteVersion` и способ проверки.

## Q29 (этап 4.3) — поддержка sqlite3_flutter_libs 0.5.41
README закреплённой `sqlite3_flutter_libs` 0.5.41 помечает пакет obsolete после перехода `sqlite3` на 3.x и указывает окончание поддержки в начале 2026 года. Этап закрепляет её совместно с `sqlite3` 2.4.5, потому что `sqlite3_flutter_libs` 0.6.0+eol ничего не поставляет. TODO(verify): определить поддерживаемый upstream-способ поставки bundled SQLite после обновления `sqlite3`/Flutter и не обновлять пакет отдельно без проверки native ABI и `StorageInfo.sqliteVersion`.

## Q30 (этап 4.4) — dart2wasm для drift/sqlite3 WASM

Web StorageBackend и Chrome runtime проверены с dart2js. `sqlite3` 2.4.5 обозначает dart2wasm support как экспериментальный и ограниченный; приложение через dart2wasm не собиралось. TODO(verify): после проверки совместимости закреплённых `drift`/`sqlite3` собрать web-приложение с dart2wasm и прогнать storage contract в целевом Chrome.

## Q31 (этап 4.4) — browser reload и две вкладки

Автоматизированный Chrome тест проверяет запись и чтение через новый экземпляр БД в той же тестовой странице; фактическая перезагрузка app page тестом не выполняется. Две вкладки также оставлены ручному QA, так как `dart test -p chrome` запускает suite в одной странице. TODO(verify): определить поддерживаемый workspace browser/integration runner, который запускает приложение на настоящей странице, повторно открывает после reload и создаёт вторую вкладку; до появления такого теста выполнить чек-лист из `docs/MANUAL_QA.md`.

## Q32 (этап 4.5) — дрейф HLC на целевых устройствах
`packages/core_sync/lib/src/hlc_validator.dart:17` содержит TODO(verify): измерить реальный дрейф часов Android/iOS/Linux/Web и уточнить `maxClockSkewMs = 30 000`. Значение выбрано как компромисс между допуском NTP-дрейфа и окном replay; измерения на устройствах не выполнялись.

## Q33 (этап 4.5) — независимая сверка BIP-39 wordlist и NFKD
`packages/core_crypto/test/bip39_integrity_test.dart:55` требует независимой сверки SHA-256 эталонного wordlist, а строка 172 фиксирует отказ от Unicode-нормализации без пакета `unorm_dart`. Обе проверки остаются TODO(verify); текущие тесты используют встроенный эталон и явно отклоняют не-ASCII парольные фразы.
