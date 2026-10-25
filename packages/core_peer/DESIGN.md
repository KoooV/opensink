# core_peer — design doc (прямые WebRTC-соединения)

## 1. Границы

Слой реализует `PeerLink` и `Transport` только для прямых соединений. Relay/SFU и
медиатопологии остаются в `core_relay`/`core_media`. Signaling не дублируется:
`WebRtcTransport` использует `RichSignalingChannel` слоя 5 (`packets`/`publishTo`)
и кодирует SDP/ICE в JSON-конверт `PeerSignal` версии 1. Если канал реализует
`NeighborAnnouncer`, транспорт публикует в hello актуальные direct-линки
(`connected`/`disconnected`), не ведя собственную топологию.

`core_peer` не импортирует `dart:io`, `dart:html`, `package:web`, `dart:js_interop`.
Платформенные различия WebRTC спрятаны за `RtcPeerFactory`/`RtcPeerConnection`;
единственная реализация — `FlutterRtcPeerFactory` поверх `flutter_webrtc`.

## 2. Perfect negotiation и роли

- `polite = compare(localPeerId, remotePeerId) < 0` (лексикографически по 32 байтам).
  Сравнение симметрично и детерминировано на обеих сторонах.
- `onRenegotiationNeeded` запускает offer, если ссылка ещё не `connected`.
  После установления соединения повторные события платформы игнорируются; явный
  запрос — `restartIce()`.
- При коллизии impolite игнорирует встречный offer. Polite ждёт завершения своей
  навигации, делает `rollback`, применяет remote offer и отвечает.
- `rollback` подтверждён на native Linux (real glare-тест). Fallback с
  пересозданием PeerConnection сохранён для платформ/сборок без rollback.
- Каналы создаёт инициатор соединения. При одновременном `connect()` оба создают
  каналы: impolite оставляет свои, polite заменяет локальные на каналы impolite.
  Это устраняет дубликаты без negotiated-каналов.
- Passively созданная ссылка не создаёт каналы до первого offer. При reconnect
  каналы создают обе стороны, а offer несёт `reset=true`; получатель полностью
  пересоздаёт PeerConnection, а не переиспользует старую SCTP-ассоциацию.

## 3. Каналы и backpressure

| label | ordered | reliability | назначение |
|---|---|---|---|
| `control` | да | reliable | управление, `Transport.send` |
| `sync` | да | reliable | синхронизация событий |
| `file` | да | reliable | файлы, backpressure |
| `presence` | нет | `maxRetransmits=0` | presence (опционально) |

Для `file`: `bufferedAmountLowThreshold = low`, отправка ждёт, пока
`bufferedAmount > highWater`, и возобновляется по `onBufferedAmountLow` или
poll-таймеру при `bufferedAmount <= low`. Отправка в каждый label сериализована
очередью, чтобы не нарушать порядок. `Incoming` отдаёт границы сообщений WebRTC
без собственного фрейминга.

## 4. ICE, сеть, таймауты

- Конфиг: список публичных STUN (`defaultPublicStun`) + override, `unified-plan`,
  `max-bundle`, `rtcpMuxPolicy=require`, `iceCandidatePoolSize`.
- Кандидаты не фильтруются: IPv6-кандидаты сохраняются. На web набор кандидатов
  определяет браузер, на native — libwebrtc. Отдельного флага нет, чтобы не
  создавать no-op API.
- `disconnected` → grace-таймер → `restartIce()`; смена сети
  (`NetworkChangeSource`) → `restartIce()` на всех ссылках.
- `restartIce()` вызывает `RTCPeerConnection.restartIce()` и offer с
  `{iceRestart:true}`. Таймаут ICE restart → полный reconnect.
- Таймауты: connect, ICE restart, disconnected grace, stats interval, backoff.
- Reconnect: экспоненциальный backoff `base * 2^(n-1)` с jitter ±25 %, лимит
  попыток; после лимита состояние `failed`. Стабильный `PeerLink` сохраняет
  `stateStream`/`incoming` между пересозданиями.

## 5. Политика соединений

`PeerPriorityPolicy` задаёт приоритет и защиту от вытеснения. При достижении
`maxConcurrentLinks` транспорт вытесняет ссылку с минимальным приоритетом, если
новый peer приоритетнее и жертва не защищена. Иначе — `PeerCapacityExceeded`.
Приоритеты задаёт верхний слой (активные группы/голосовые каналы).
`StaticPeerPriorityPolicy` принимает наборы `protected`/`priorities` и позволяет
атомарно обновить их через `replace` при смене активности.

## 6. Статистика

`PeerLink.stats` обновляется периодическим `getStats()`:
- RTT: `candidate-pair.currentRoundTripTime` (секунды). Если он 0 — среднее
  `totalRoundTripTime / responsesReceived`. Linux и Android проверены
  integration-тестами; внутреннее представление — микросекунды.
- байты: `candidate-pair.bytesSent/bytesReceived`, fallback — `transport`,
  затем счётчики каналов;
- потери: `remote-inbound-rtp`/`inbound-rtp` `packetsLost/(packetsLost+received)`,
  иначе 0 (у data-channel нет RTP-потерь);
- исходящий битрейт: дельта `bytesSent` за интервал, бит/с.

## 7. Различия web/native (flutter_webrtc 1.6.2+hotfix.4, dart_webrtc 1.8.2)

| Область | Web | Native |
|---|---|---|
| Фабрика | `dart_webrtc`/browser API через conditional export | method channel плагина |
| `bufferedAmount` | синхронный getter | синхронный getter; `getBufferedAmount()` в 0.10.8 может быть UnimplementedError |
| `close` | достаточно `close()` | `close()` + `dispose()` (в try/catch) |
| rollback | поддерживается браузером | подтверждён на Linux; fallback — пересоздание |
| `signalingState` до первого события | обычно `stable` из JS | `null` до первого события; обёртка считает null `stable` и обновляет кэш через `onSignalingState` |
| ICE/STUN | политика браузера, IPv6 обычно включён | libwebrtc; кандидаты не фильтруются |
| `iceCandidatePoolSize` | может игнорироваться | учитывается плагином |
| stats keys | стандартные WebRTC | те же имена; `currentRoundTripTime` может быть 0, используется `totalRoundTripTime/responsesReceived` |
| `maxRetransmits` | поддерживается | поддерживается; presence может быть недоступен на старых сборках |

## 8. Критерии приёмки

1. Два fake-пира через fake signaling слоя 5 устанавливают соединение и
   обмениваются сообщениями в обе стороны.
2. Одновременный connect (glare) завершается одним рабочим соединением.
3. `file` соблюдает backpressure; `presence` может быть unreliable.
4. Смена сети вызывает ICE restart и не рвёт трафик.
5. Сбой соединения переподключается с backoff; лимит ссылок вытесняет
   низкоприоритетного peer.
6. `close()` отправляет hangup и корректно закрывает обе стороны.
7. `PeerLink.stats` отдаёт RTT, потери и исходящий битрейт.
8. Реальный WebRTC проходит сценарии на Chrome, native Linux и Android
   (connect, control/sync/file, ICE restart, close). Glare и full reconnect
   подтверждены на Linux и fake-RTC; Android chaos-тесты вынесены из CI из-за
   таймингов эмулятора.

## 9. Известные ограничения

- Web-стек: `flutter_webrtc 1.6.2+hotfix.4`, `dart_webrtc 1.8.2`,
  `web 1.1.2`, `drift 2.31.0`, `sqlite3 2.9.4`; web-assets закреплены в
  `tool/web_assets.lock`. Реальный Chrome-тест проходит.
- `flutter test` не регистрирует нативный плагин Linux, поэтому Linux-сценарий
  требует `integration_test`/собранного приложения.
- SDP не мангируется; кодек/битрейт медиа — задача `core_media`.
- `currentRoundTripTime` трактуется как секунды (спецификация WebRTC); на
  Linux/Android проверено. При нулевом значении используется среднее
  `totalRoundTripTime/responsesReceived`.
- `StaticPeerPriorityPolicy` — готовая точка подключения; источник «активности»
  (группы/каналы) по-прежнему задаёт верхний слой.
- `PeerLinkStats.loss` для data-channel всегда 0: WebRTC не отдаёт потери
  пакетов для SCTP; ненулевые значения возможны только при наличии RTP-медиа
  (`inbound-rtp`/`remote-inbound-rtp`).
