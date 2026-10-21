# ADR-001: Каркас монорепозитория OpenSink

## Статус
Принято

## Контекст
Кроссплатформенный (Linux, Android, Web) P2P-мессенджер без собственного сервера. Внешняя инфраструктура только как публичные STUN, Nostr-реле и WebSocket-трекеры (bootstrap/signaling). Стек: Flutter stable, Dart 3, melos, riverpod, protobuf, package:cryptography, drift.

## Решения

### 1. Структура репозитория (melos workspace)
Монорепо под управлением [melos](https://pub.dev/packages/melos). Корень — мета-пакет, все пакеты в `packages/` и `apps/`:

| Пакет | Назначение | Зависит от dart:io/html |
|---|---|---|
| `core_domain` | Модели и интерфейсы домена | Нет |
| `core_crypto` | Идентичность, Ed25519, package:cryptography | Нет |
| `core_protocol` | Protobuf схемы, envelope | Нет |
| `core_storage` | Drift event store | Нет |
| `core_signaling` | Nostr, трекеры, LAN, QR | Нет |
| `core_peer` | WebRTC через flutter_webrtc | Нет |
| `core_sync` | Лог событий, синхронизация | Нет |
| `core_group` | Группы, права | Нет |
| `core_relay` | Маршрутизация через участников | Нет |
| `core_media` | Звонки, экран, топологии | Нет |
| `platform_*` | Платформенные реализации (conditional import) | Да (внутри platform_*) |
| `apps/app` | UI (Flutter) | Да |

Все `core_*` пакеты — чистый Dart, не импортируют `dart:io` и `dart:html`. Платформенный код только в `platform_*` и `apps/app`.

### 2. Контракты (core_domain)
Каждый внешний порт скрыт за абстрактным интерфейсом с in-memory fake:

- `Identity` / `Signer` — Ed25519 идентичность и подпись (контракты в домене, реализация в `core_crypto`).
- `PeerId` — узел сети (открытый ключ Ed25519, байты). `GroupId`, `ChannelId`, `UserId` — строковые идентификаторы.
- `SignalingChannel` — `join(topic)`, `publish(topic, bytes)`, `Stream<SignalingMessage>`.
- `PeerLink` — `send(channel, bytes)`, `Stream<Incoming>`, `state`, `stats` (RTT, bytes, loss), `close()`.
- `Transport` — `connect(peerId)`, `Stream<PeerLinkEvent>`, `send(dst, bytes)` (прямой путь или Relay).
- `Relay` — `routes(dst)`, `forward(frame)`, `capacity`.
- `MediaTopology` — `plan(participants, capabilities) -> TopologyPlan` (mesh или hosted-by-peer).
- `EventStore`, `SyncEngine`, `IGroupState`, `SecureKeyStore`, `ScreenCaptureSource`.

### 3. Доменная логика
- `sealed class Result<T, E>` вместо исключений для бизнес-ошибок.
- Состояние группы — чистая функция от множества подписанных событий (`Group.apply`).
- Любое событие группы подписано Ed25519 и валидируется до применения.
- Секреты не попадают в логи.

### 4. DI
Riverpod (`flutter_riverpod`). Провайдеры в `apps/app/lib/di/providers.dart` связывают интерфейсы с fakes для разработки/тестов; в продакшене — с реальными реализациями из `core_*` и `platform_*`.

### 5. Линтинг и CI
- Строгие правила в корневом `analysis_options.yaml` (на базе `flutter_lints/flutter.yaml`, лишние правила как ошибки).
- CI (GitHub Actions): `melos run analyze`, `melos run test`, проверка отсутствия `dart:io`/`dart:html` в `core_*`, сборки `flutter build web` / `linux` / `apk` для `apps/app`.

### 6. Именование
- Код и идентификаторы — английский.
- Комментарии к решениям и документация — русский.
- Интерфейсы без префикса `I` (кроме `IGroupState` для читаемости, так как `GroupState` — модель).
- Файлы в `snake_case`, классы в `PascalCase`.

## Открытые вопросы (TODO(verify))
- API десеализации Ed25519 подписи из hex в `package:cryptography` v3 (`Ed25519Signature.fromHex`).
- Точная схема protobuf envelope (core_protocol) — требует отдельного design doc.
- Реализация SecureKeyStore на Android Keystore / Linux libsecret / Web Crypto API.
- flutter_webrtc версия и поддержка Linux/Web.

## Критерии приёмки
- `melos run analyze && melos run test` — зелёные.
- Три сборки (`web`, `linux`, `apk`) проходят.
- Ни один `core_*` пакет не импортирует `dart:io` / `dart:html`.
