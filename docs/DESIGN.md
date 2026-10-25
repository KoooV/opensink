# Design doc: OpenSink (общее состояние)

Документ описывает текущее устройство и состояние репозитория. История фаз разработки
не хранится в `docs/`: для неё используйте `git log`. Открытые риски и вопросы
перечислены в `docs/DEFECTS.md` и `docs/OPEN_QUESTIONS.md`.

## 1. Продукт и границы

OpenSink — кроссплатформенный P2P-мессенджер (Linux, Android, Web) в стиле Discord:
группы, текстовые и голосовые каналы, демонстрация экрана со звуком. Собственного
сервера нет. Внешняя инфраструктура допускается только для bootstrap/signaling:
публичные STUN, публичные Nostr-реле и WebSocket-трекеры.

## 2. Стек и закреплённые версии

| Компонент | Версия | Источник |
|-----------|--------|----------|
| Dart SDK | 3.13.5 | `pubspec.yaml` |
| Flutter | 3.47.7 (stable) | окружение разработки |
| Melos | 8.9.0 | `pubspec.lock` |
| `package:cryptography` | 2.9.0 | `pubspec.lock` |
| `bip340` | 0.3.1 | `pubspec.lock` |
| `drift` | 2.31.0 | `pubspec.lock` |
| `sqlite3` | 2.9.4 | `pubspec.lock` |
| `sqlite3_flutter_libs` | 0.5.41 | `pubspec.lock` |
| `flutter_secure_storage` | 9.2.4 | `pubspec.lock` |
| `flutter_webrtc` | 1.6.2+hotfix.4 | `pubspec.lock` |
| `dart_webrtc` | 1.8.2 | `pubspec.lock` |
| `web` | 1.1.2 | `pubspec.lock` |

Версии web-ресурсов Drift и SQLite закреплены в `tool/web_assets.lock`, SHA-256 — в
`tool/web_assets.sha256`.

## 3. Пакеты и текущий статус

Все `core_*` пакеты — чистый Dart без `dart:io`, `dart:html`, `package:web` и
`dart:js_interop` (проверяется `tool/check_core_imports.sh`). Платформенный код
находится только в `platform_*` и `apps/app`.

| Пакет | Назначение | Состояние |
|-------|------------|-----------|
| `core_domain` | Модели, `Result<T, E>`, интерфейсы портов, in-memory fakes | Реализовано |
| `core_crypto` | Identity, Ed25519, X25519, AEAD, HKDF, BIP-39, X3DH, Double Ratchet, Sender Keys, StateVault | Реализовано |
| `core_protocol` | Protobuf-подобный wire-формат, `Envelope`, 10 типов сообщений, лимиты, кодек | Реализовано |
| `core_storage` | Drift-схема v7, `DriftEventStore`, `SyncEventStore`, миграции, retention | Реализовано |
| `core_signaling` | Nostr (NIP-01), WebTorrent-трекеры, пул реле, защищённый signaling-кодек | Реализовано; LAN/QR отсутствуют |
| `core_peer` | WebRTC `PeerLink`/`Transport`, perfect negotiation, каналы, статистика | Реализовано |
| `core_sync` | HLC-лог, anti-entropy, gossip, приоритетная загрузка, tombstones, pending | Реализовано |
| `core_group` | Роли, права, инвайты, конфликты, чистая проекция группы | Реализовано |
| `core_relay` | Маршрутизация через участников группы | Реализовано: direct-first fallback, TTL, антипетли, лимиты, Ed25519-подпись origin с nonce, `PeerChannels.relay`, opt-in default; R-01…R-10 закрыты, открыты R-11…R-15 |
| `core_media` | Звонки, демонстрация экрана, топологии | Заглушка (`TODO(verify)`) |
| `platform_android` | SecureKeyStore (Keystore), SQLite-фабрика | Реализовано |
| `platform_linux` | SecureKeyStore (libsecret), SQLite-фабрика | Реализовано |
| `platform_web` | SecureKeyStore (IndexedDB + Web Crypto), SQLite WASM-фабрика | Реализовано |
| `apps/app` | Flutter-шелл и DI | Минимальный UI; подключены storage, sync и identity |

## 4. Криптография (`core_crypto`)

Используются только примитивы из `package:cryptography`; собственных криптопримитивов
нет.

- **AEAD** — XChaCha20-Poly1305: nonce 24 байта, ключ 32 байта, MAC 16 байт.
  Wire-формат: `nonce(24) || ciphertext || mac(16)`. Ошибки расшифровки не раскрывают
  причину.
- **Identity** — BIP-39 (встроенный английский wordlist), seed через
  PBKDF2-HMAC-SHA-512 (2048 итераций), Ed25519 и X25519 из одного seed.
  X25519-ключ привязан подписью Ed25519.
- **X3DH** — ослабленный вариант без one-time prekeys: IK + SPK. Публичный SPK
  подписан Ed25519-ключом IK с доменным префиксом.
- **Double Ratchet** — X25519 DH-шаг, HKDF-SHA-256, `maxSkip = 100`,
  TTL пропущенных ключей 24 часа, лимит `messageNumber = 2^30`, сериализация v1.
  Состояние не мутируется при неудачной расшифровке.
- **Sender Keys** — цепочка ключей, Ed25519-подпись, независимое окно replay по
  отправителю, лимит `sequenceNumber = 2^30`, ротация цепочки и ключа подписи.
- **StateVault** — XChaCha20-Poly1305 поверх сериализованного состояния; ключ
  хранилища случайный, лежит в `SecureKeyStore`, не выводится из identity seed.
- **SecureKeyStore** — контракт в `core_domain`, реализации в `platform_*`.
  Секреты не попадают в `toString()` и сообщения ошибок.

## 5. Протокол (`core_protocol`)

`Envelope` содержит поля: `version`, `type`, `sender` (Ed25519 public key), `hlc`,
`payload`, `signature`. Подпись считается над `signatureData()`: поля 1–4 и
`payload`. `unknownFields` сохраняются для пересылки, но не входят в зону подписи и
не должны влиять на решения о доставке.

Типы сообщений: `chatEvent`, `groupEvent`, `syncRequest`, `syncResponse`,
`fileChunk`, `fileRequest`, `presence`, `callControl`, `relayFrame`, `leaderLease`.

Лимиты: конверт ≤ 1 MiB, payload ≤ 512 KiB, файловый чанк ≤ 256 KiB, строка ≤ 64 KiB,
не более 4096 повторяющихся элементов. Неизвестная будущая версия конверта
декодируется структурно, но не обрабатывается семантически.

## 6. Хранение (`core_storage`)

Drift-схема v7. Основные таблицы: `events`, `groups`, `members`, `channels`, `peers`,
`blobs_meta`, `sync_state`, `pending_events`, `schema_info`, `group_settings`.
События `events` неизменяемы: `UPDATE`/`DELETE` запрещены SQLite-триггерами.
`pending_events` — отдельная изменяемая очередь для событий, ожидающих membership.

Инварианты `EventStore`:

- `author` обязателен (64 hex-символа = 32 байта), `id` — ASCII `[A-Za-z0-9._:-]`,
  1–128 символов; хранилище не разбирает payload и не проверяет подпись;
- дубль `id` не перезаписывает исходные байты;
- порядок выборки детерминирован по `(hlc, id)`;
- минимум SQLite 3.24.0 проверяется при открытии.

Платформенные фабрики открывают `NativeDatabase`/`WasmDatabase` и возвращают
`StorageInfo` с фактической версией SQLite. `core_storage` не содержит платформенных
импортов.

## 7. Синхронизация (`core_sync`)

- `Hlc = (physicalMs, counter)`; `observe()` двигает локальные часы за удалённые.
- `event.id = hex(SHA-256("opensink/sync/event-id/v1|" || canonical))`; подпись
  Ed25519 — над `"opensink/sync/event-signature/v1|" || canonical`.
- Порядок приёма: размер → id → подпись → membership → `prevId` → дедупликация →
  запись. Неизвестный автор попадает в `pending`, удалённый — отклоняется.
- Anti-entropy идёт по HLC-бакетам 60 с; кадр ≤ 1 MiB, ≤ 128 событий.
- Gossip: дедупликация по id, `hops ≤ 4`, token bucket, LRU отправленных.
- Последние сообщения канала загружаются приоритетно; история — по явному запросу.
- Правки и удаления — отдельные события; проекция применяет tombstones после
  создания сообщений.

## 8. Signaling и peer

- `core_signaling`: Nostr NIP-01 с ephemeral-событиями, WebTorrent announce/offer/
  answer, пул реле с health/backoff, защищённый кодек `opensink:1:base64url`,
  rate limit и replay-кэш 5 минут. LAN/QR не реализованы.
- `core_peer`: perfect negotiation (polite/impolite по `PeerId`), каналы
  `control`/`sync`/`file`/`presence`, backpressure по `bufferedAmount`, ICE restart
  при смене сети, reconnect с backoff, лимит ссылок, `getStats`. Flutter-адаптер
  вынесен в `package:core_peer/core_peer_flutter.dart`.
- STUN: публичные серверы по умолчанию; TURN не предусмотрен.

## 9. Приложение

`apps/app` пока содержит минимальный Flutter-шелл. Через Riverpod подключены
платформенное хранилище, `DriftEventStore`, Ed25519-identity, `CryptoSigner` и
`SyncEngineImpl` и `Relay`. Остальные порты (`SignalingChannel`, `Transport`,
`MediaTopology`, `IGroupState`, `ScreenCaptureSource`) остаются fakes или
заглушками до реализации соответствующих слоёв.

## 10. Ограничения и открытые риски

- `core_media` не реализован; `core_relay` подключён в DI вместе с подписью и каналом `relay`, остальные сетевые порты — fakes (`Q2`); `core_group` ещё не подключён к `core_sync`.
- UI не покрывает продуктовые сценарии из `docs/UI_UX.md`.
- Runtime-версия SQLite в собранных Android/Linux приложениях не подтверждена.
- Открытые дефекты и остаточные риски: `D-14`, `D-21`, `D-22`, `D-23` в
  `docs/DEFECTS.md`.
- Публичные реле/трекеры и LAN/QR остаются открытыми вопросами (`Q17`, `Q35`).

## 11. Проверки

```bash
dart analyze
bash tool/check_core_imports.sh
bash tool/check_core_storage_deps.sh
bash tool/check_text_hygiene.sh
bash tool/check_docs_drift.sh
```

Тесты запускаются через `melos run test`; web- и real-WebRTC сценарии — скриптами
`tool/test_web_*.sh` и CI job-ами.

## 12. Документы

- `docs/ADR.md` — архитектурные решения и границы.
- `docs/DEFECTS.md` — открытые дефекты и остаточные риски.
- `docs/OPEN_QUESTIONS.md` — открытые вопросы и индекс `TODO(verify)`.
- `docs/REVIEW_LIST.md` — карта файлов для ручного ревью.
- `docs/ENVELOPE_ONLY_SIGNING.md` — модель подписи на уровне конверта.
- `docs/MANUAL_QA.md` — ручные проверки хранилищ.
- `docs/UI_UX.md` — гайд по интерфейсу.
- `packages/*/DESIGN.md` — детальные design doc-и пакетов.
