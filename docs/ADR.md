# ADR-001: Каркас монорепозитория OpenSink

## Статус
Принято; действует для текущего состояния репозитория.

## Контекст
Кроссплатформенный (Linux, Android, Web) P2P-мессенджер без собственного сервера.
Внешняя инфраструктура допускается только как публичные STUN, Nostr-реле и
WebSocket-трекеры для bootstrap/signaling. Стек: Flutter stable, Dart 3, melos,
riverpod, protobuf, `package:cryptography`, drift.

## Решения

### 1. Структура репозитория (melos workspace)
Монорепо под управлением melos. Корень — мета-пакет, пакеты находятся в `packages/`
и `apps/`.

| Пакет | Назначение | Состояние |
|-------|------------|-----------|
| `core_domain` | Модели, `Result`, интерфейсы, fakes | Реализовано |
| `core_crypto` | Identity, Ed25519/X25519, AEAD, E2EE, StateVault | Реализовано |
| `core_protocol` | Wire-формат, `Envelope`, сообщения, лимиты | Реализовано |
| `core_storage` | Drift-схема v7, `EventStore`, `SyncEventStore` | Реализовано |
| `core_signaling` | Nostr, WebTorrent-трекеры, пул реле | Реализовано; LAN/QR отсутствуют |
| `core_peer` | WebRTC `PeerLink`/`Transport` | Реализовано |
| `core_sync` | HLC-лог, anti-entropy, gossip | Реализовано |
| `core_group` | Группы, права | Заглушка |
| `core_relay` | Маршрутизация через участников | Заглушка |
| `core_media` | Звонки, экран, топологии | Заглушка |
| `platform_*` | SecureKeyStore и SQLite-фабрики | Реализовано |
| `apps/app` | Flutter UI и DI | Минимальный шелл |

`core_*` не импортируют `dart:io`, `dart:html`, `package:web` и `dart:js_interop`.
`core_peer` содержит Flutter-адаптер в отдельной библиотеке
`package:core_peer/core_peer_flutter.dart`; чистые интерфейсы остаются в
`package:core_peer/core_peer.dart`. Платформенный код — только в `platform_*` и
`apps/app`.

### 2. Контракты (`core_domain`)
Каждый внешний порт скрыт за интерфейсом с in-memory fake:

- `Identity`, `Signer` — Ed25519-идентичность и подпись.
- `PeerId`, `GroupId`, `ChannelId`, `UserId`, `EventId` — идентификаторы.
- `SignalingChannel` — join/publish/stream.
- `PeerLink` — send/receive, state, stats, close.
- `Transport` — connect, события, отправка напрямую или через relay.
- `Relay` — routes, forward, capacity.
- `MediaTopology` — plan(participants, capabilities).
- `EventStore`, `SyncEventStore`, `SyncEngine`, `IGroupState`, `SecureKeyStore`,
  `EncryptedStateStore`, `ScreenCaptureSource`.

### 3. Доменная логика
- `sealed class Result<T, E>` вместо исключений для бизнес-ошибок.
- Состояние группы — чистая функция от подписанных событий.
- События, влияющие на состояние группы, подписаны Ed25519 и валидируются до
  применения.
- Секреты не попадают в логи и `toString()`.

### 4. DI
Riverpod. Провайдеры в `apps/app/lib/di/providers.dart` подключают платформенное
хранилище, `DriftEventStore`, identity, `CryptoSigner` и `SyncEngineImpl`. Для
`SignalingChannel`, `PeerLink`, `Transport`, `Relay`, `MediaTopology`, `IGroupState`
и `ScreenCaptureSource` пока используются fakes/заглушки до реализации слоёв.

### 5. Линтинг и CI
- Строгие правила в корневом `analysis_options.yaml`.
- CI: `melos run analyze`, `melos run test`, `tool/check_text_hygiene.sh`,
  проверка отсутствия `dart:io`/`dart:html` в `core_*`, Chrome-прогоны
  `core_crypto`/`core_signaling`/`core_sync`/`platform_web`, real-WebRTC и
  Android job.
- Локальные проверки документации: `tool/check_docs_drift.sh`,
  `tool/check_core_imports.sh`, `tool/check_core_storage_deps.sh`.

### 6. Именование
- Код и идентификаторы — английский.
- Комментарии к решениям и документация — русский.
- Интерфейсы без префикса `I` (кроме `IGroupState`, где `GroupState` — модель).
- Файлы в `snake_case`, классы в `PascalCase`.

## Открытые вопросы
Актуальный список — `docs/OPEN_QUESTIONS.md`. Ключевые блокеры: реализация
`core_group`, `core_relay`, `core_media`; production DI для signaling/peer; LAN/QR;
проверка runtime SQLite и публичных реле/трекеров.

## Критерии приёмки
- `dart analyze` — без ошибок и предупреждений.
- `melos run test` — зелёный.
- `bash tool/check_core_imports.sh`, `bash tool/check_core_storage_deps.sh`,
  `bash tool/check_text_hygiene.sh`, `bash tool/check_docs_drift.sh` — зелёные.
- Ни один `core_*` пакет не импортирует `dart:io`/`dart:html`.
