# Открытые вопросы core_crypto (фундамент 0)

## Индекс TODO(verify) в коде (этап 4.5)

Каждая строка соответствует одному маркеру `TODO(verify)` в `.dart`-файлах `packages/` и `apps/`. Команда сверки и результат — в `docs/LAYER4_ACCEPTANCE.md`, раздел AC-документации.

| # | Маркер | Вопрос |
|---|--------|--------|
| TODO-01 | `packages/core_crypto/test/bip39_integrity_test.dart:55` | Q33 |
| TODO-02 | `packages/core_crypto/test/bip39_integrity_test.dart:172` | Q33 |
| TODO-03 | `packages/core_group/lib/core_group.dart:3` | Q12 |
| TODO-04 | `packages/core_media/lib/core_media.dart:3` | Q13 |
| TODO-06 | `packages/core_relay/lib/core_relay.dart:3` | Q16 |
| TODO-08 | `packages/core_storage/test/schema_v3_snapshot.dart:3` | Q26 |
| TODO-09 | `packages/core_sync/lib/core_sync.dart:5` | Q19 |
| TODO-10 | `packages/core_sync/lib/src/hlc_validator.dart:17` | Q32 |
| TODO-11 | `packages/core_signaling/lib/src/nostr_signaling.dart:31` | Q17 |
| TODO-12 | `packages/core_signaling/lib/src/tracker_signaling.dart:28` | Q17 |

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

## Q14 — core_peer: flutter_webrtc реализация PeerLink / Transport — ЗАКРЫТО (2026-10-23)

Реализованы `WebRtcPeerLink` и `WebRtcTransport`: perfect negotiation
(polite/impolite по PeerId), control/sync/file/presence, backpressure по
`bufferedAmount`, STUN/IPv6-политика, ICE restart и reconnect с backoff,
лимит ссылок и приоритеты (`StaticPeerPriorityPolicy`), `getStats`
(RTT/потери/битрейт). Адаптер `flutter_webrtc` вынесен в
`package:core_peer/core_peer_flutter.dart`.

Приёмка (2026-10-23):
- fake-signaling + fake RTC: VM и Chrome — зелёные;
- реальный WebRTC Chrome — зелёный;
- реальный WebRTC native Linux: connect, control/sync/file, ICE restart,
  glare, full reconnect — зелёные;
- Android emulator (основной сценарий) — зелёный;
- STUN smoke — зелёный;
- design doc: `packages/core_peer/DESIGN.md`, приёмка:
  `docs/LAYER6_ACCEPTANCE.md`.

Закрыто в этом проходе:
- **PEER-OPEN-01**: web-стек обновлён (`flutter_webrtc 1.6.2`,
  `dart_webrtc 1.8.2`, `web 1.1.2`, `drift 2.31.0`, `sqlite3 2.9.4`),
  web-assets пересобраны; Chrome real-тест проходит.
- **PEER-OPEN-02**: Linux Android integration runner и `test_driver` добавлены.
- **PEER-OPEN-03**: native rollback подтверждён на Linux; fallback сохранён.
- **PEER-OPEN-04**: `currentRoundTripTime` — секунды; при 0 используется
  `totalRoundTripTime/responsesReceived`; Linux/Android проверены.
- **PEER-OPEN-05 (частично)**: `enableIpv6Candidates` удалён как no-op;
  `presence` unreliable остаётся опциональным.

Остаются открытыми:
- Android chaos-сценарии (glare/full reconnect) не в CI из-за таймингов
  эмулятора; подтверждены на Linux и fake-RTC (`PEER_CHAOS=false` для Android).
- `presence` unreliable на старых native-сборках (флаг
  `enableUnreliablePresence`).
- `loss` для data-channel всегда 0; это семантика WebRTC/SCTP, зафиксирована
  в `core_domain`.

## Q15 — core_protocol: protobuf схемы и конвертеры envelopes
`// TODO(verify): protobuf схемы и конвертеры envelopes.` (packages/core_protocol/lib/core_protocol.dart:3)

## Q16 — core_relay: Relay реализация маршрутизации через участников группы
`// TODO(verify): Relay реализация маршрутизации через участников группы.` (packages/core_relay/lib/core_relay.dart:3)

## Q17 — core_signaling: Nostr, трекеры, LAN, QR реализации SignalingChannel — ЧАСТИЧНО ЗАКРЫТО
Реализованы `NostrSignaling` (NIP-01, ephemeral kind 21000, BIP-340 обёртка, пул реле) и
`TrackerSignaling` (WebTorrent announce/offer/answer, пул трекеров). Общий защищённый
конверт, presence, replay/rate limit и reconnect/health описаны в
`packages/core_signaling/DESIGN.md`; тесты — `packages/core_signaling/test/`.

Решения владельца зафиксированы в `packages/core_signaling/DESIGN.md` §7
(poll 2026-10-23, два раунда):
- membership: `GroupSecret` + опциональные `allowedPeers`/`isAuthorized`;
- публичные реле/трекеры по умолчанию остаются с `TODO(verify)`;
- наш конверт остаётся в `sdp` как `opensink:1:base64url` с `TODO(verify)`;
- NIP-01 JSON сверен с V8 `JSON.stringify` (`test/nostr_json_interop_test.dart`);
- LAN/QR — вне этого слоя;
- hello 20 с / presence TTL 60 с;
- rate limit 40/20 глобально и 20/10 на отправителя;
- дедупликация пула 5 минут по `(topic, kind, from, recipient, body)`;
- `topic` включён в AAD (wire v2) — cross-topic replay закрыт;
- NIP-42 AUTH отложен; neighbors caller-supplied; replay-кэш in-memory 5 минут;
- health-score стартует с 0.0;
- web-тесты добавлены: `test/signaling_web_test.dart` (Chrome, dart2js и dart2wasm).

Остаются открытыми:
- TODO(verify): актуальные публичные реле/трекеры и их политика;
- TODO(verify): совместимость не-SDP `sdp` с конкретными публичными трекерами;
- TODO(verify): NIP-42 AUTH у части публичных Nostr-реле;
- LAN/QR реализации `SignalingChannel` (в этом слое не делались);
- сценарий держателя инвайта без `group_secret` (отложен);
- реальный браузерный `WebSocket.connect` к сетевому серверу в CI не проверяется
  (web-тесты используют fake-реле на `package:web_socket/testing.dart`).

## Q18 — core_storage: drift-схема и реализация EventStore — ЗАКРЫТО
Реализовано в этапах 4.0–4.8: схема v6, `AppDatabase`, `DriftEventStore`, миграции, native- и web-фабрики, общий portable test suite. Маркер `TODO(verify)` из `packages/core_storage/lib/core_storage.dart` удалён. Доказательства — `docs/LAYER4_ACCEPTANCE.md`.

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

## Q34 (этап 4.8) — канонический event id и контракт хэша
В задании слоя 4 указано `id = хэш`, но `EventRecord.id` в `core_domain` задаётся вызывающим слоем, а хранилище проверяет только форму ASCII `[A-Za-z0-9._:-]{1,128}`. Хранилище намеренно не вычисляет и не пересчитывает content hash: канонический набор байтов (envelope, подпись, HLC, group/channel) и алгоритм ещё не зафиксированы в `core_protocol`/`core_sync`. TODO(verify): утвердить формулу event id на слое 7, добавить проверку соответствия `id` хэшу на границе записи (или отдельный канонический кодировщик) и тест на несовпадение. До этого `id` трактуется как непрозрачный caller-supplied хэш, а идемпотентность обеспечивается первичным ключом.

## Q35 (core_signaling) — открытые задачи после poll 2026-10-23

Решения poll зафиксированы в `packages/core_signaling/DESIGN.md` §7. Ниже — actionable backlog с критериями закрытия. Статусы: `open` — не начато; `deferred` — сознательно отложено; `accepted-risk` — риск принят, код не меняем; `closed` — закрыто.

| ID | Задача | Статус | Следующий шаг | Критерий закрытия |
|---|---|---|---|---|
| SIG-OPEN-01 | Держатель инвайта без `group_secret` | deferred | Design doc: invite-token, `GroupSecret.invitationKey()`, отдельный authorizer/ключ; не переиспользовать payload-ключ группы без явного решения. | Invite holder проходит signaling и обменивается SDP без полного `group_secret`; посторонний отклоняется; есть тесты replay/impersonation; секреты не логируются. |
| SIG-OPEN-02 | Публичные Nostr-реле и WebTorrent-трекеры | open | Проверить NIP-11 и write/read smoke, политику трекеров, закрепить список и дату, дать override через конфиг, добавить fallback. | Документированный список с датой/политикой; e2e smoke; отказ одного реле не ломает обнаружение. |
| SIG-OPEN-03 | NIP-42 AUTH | deferred | Обработать `AUTH`-челлендж, подписать его (проверить, допустим ли ephemeral secp-ключ сессии), хранить auth-state, не уходить в бесконечный reconnect при отказе. | Запись в реле, требующее AUTH; понятный backoff при auth-failure; тест с fake AUTH-реле. |
| SIG-OPEN-04 | Реальные WebTorrent-трекеры и не-SDP `sdp` | accepted-risk | Прогнать `bittorrent-tracker` server и 2–3 публичных трекера; зафиксировать матрицу `offer`/`answer`/`offer_id`/`to_peer_id`; определить fallback. | E2E через выбранный трекер; документирована несовместимость со стандартными WebTorrent-клиентами; пакеты не теряются. |
| SIG-OPEN-05 | Реальный браузерный `WebSocket.connect` | open | Поднять локальный WS-сервер (Dart VM/Node), передать URL через `--dart-define`, запустить Chrome-тест из `packages/core_signaling`; в CI — dart2js, dart2wasm опционально. | Chrome подключается к реальному WS; presence и SDP проходят; отказ одного реле не ломает сценарий. |
| SIG-OPEN-06 | LAN/QR реализации `SignalingChannel` | deferred | Отдельный слой/задача: LAN discovery и QR-инвайт за тем же интерфейсом `SignalingChannel`. | Два клиента находят друг друга по LAN/QR без интернета; тесты обнаружения и обмена SDP. |
| SIG-OPEN-07 | Персистентность replay-кэша | accepted-risk | Оценить угрозу рестарта процесса в пределах clock skew; при необходимости хранить seen nonces в `core_storage`. | Решение зафиксировано; если persistent — тест replay после рестарта. |
| SIG-OPEN-08 | Hardening `NostrEphemeralSigner` | open | Сделать `privateKeyHex` приватным, оставить test-only factory, исключить попадание ключа в `toString`/логи; зафиксировать, что zeroization в Dart не гарантируется. | Приватный ключ не входит в публичный API и логи; тесты используют factory. |

### Принятые допущения

- `GroupSecret` = членство; отдельный invite-путь отложен (SIG-OPEN-01).
- Публичные реле/трекеры остаются дефолтом с `TODO(verify)` (SIG-OPEN-02).
- `neighbors` в hello — caller-supplied; signaling не ведёт топологию.
- WebTorrent payload остаётся `opensink:1:base64url` в `sdp` (SIG-OPEN-04).
- Replay-кэш in-memory, TTL 5 минут (SIG-OPEN-07).
- Health-score неподключённого реле — `0.0`.
- Web-тесты используют fake-реле на `package:web_socket/testing.dart` (SIG-OPEN-05).

### Закрыто в этом проходе

- Cross-topic replay: `topic` включён в AAD, wire format v2; тест `rejects packet moved to another topic`.
- Web-тесты: `packages/core_signaling/test/signaling_web_test.dart` проходит в Chrome на dart2js и dart2wasm (локально); добавлен CI job `core_signaling-web` для dart2js.
- Найден и исправлен web-дефект: `dart2js` не поддерживает `ByteData.setInt64/getInt64`; timestamp кодируется двумя 32-битными половинами.
- `SignalingChannelPool` изолирует сбой backend-а и учитывает recipient в дедупликации.
- Health-score стартует с `0.0`; обновлены DESIGN и индекс `TODO(verify)`.
