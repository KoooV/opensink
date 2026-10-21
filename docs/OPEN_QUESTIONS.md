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

Браузер Chrome/Chromium присутствует (`google-chrome-stable`). `dart test -p chrome` загружает и выполняет тестовый суит корректно — MIME-тип `dart.js` не блокирует выполнение в этом окружении (строгая проверка MIME не срабатывает).

Проверено: `dart test packages/core_crypto/test/ -p chrome` — **196 пройдено, 0 провалено**. Побайтовый паритет с VM (196/196).

Логика `platform_web` (IndexedDB + AES-GCM KEK) компилируется через `dart2js` без ошибок типов. Рантайм-тестирование IndexedDB в headless Chrome требует отдельной настройки (профиль,権限), но не bloqueет приёмку.

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

## Q18 — core_storage: drift схема и реализация EventStore
`// TODO(verify): drift схема и реализация EventStore.` (packages/core_storage/lib/core_storage.dart:3)

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
