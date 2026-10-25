# core_relay

## Назначение

Прозрачная доставка, когда прямое WebRTC-соединение не установилось: `Transport`
сначала пробует прямой линк, затем один промежуточный сосед (A–C–B).

## Состав

- `RelayTopology` — граф из presence-анонсов (`neighbors`, `canRelay`, ёмкость,
  RTT, нагрузка) плюс локальные линки, подтверждённые `direct.events`
  (`connected`/`disconnected`). Устаревшие анонсы и `canRelay=false` не
  участвуют в выборе; при выборе релея достаточно линка с любой стороны
  (presence или локальный), локальный линк источника не теряется без
  presence-записи о нём.
- `RelayTransport` — реализация `Transport` с `deliver()` и `accept()`.
- `MemberRelay` — адаптер к доменному порту `Relay` (`routes`/`forward`/`capacity`).
- `RelayOptIn` — чистая политика согласия; на Android мобильный трафик и заряд
  ниже 20% выключают ретрансляцию.
- `RelayMetrics` — счётчики доставки, пересылки и отброшенных кадров.

## Путь кадра

1. `RelayTransport.send(dst, bytes)` пробует `direct.send(dst)` с
   `directTimeout`. Успех — `DirectSent`.
2. Иначе выбирается общий сосед `source ↔ relay ↔ dst` по score
   `rttMs + load / capacity * 1000`, origin подписывает кадр Ed25519 и
   отправляется `RelayFrame` в `RelayEnvelope` (тег `OSRL` v3) через
   `Transport.sendRelay` (отдельный `PeerChannels.relay`).
3. Промежуточный узел принимает кадр из `Transport.relayIncoming` в
   `accept(from, bytes)` и проверяет: полный размер → token bucket по `from` →
   тег/заголовок и длины полей → `src == local` → `src == from` на первом хопе →
   `originTtl <= maxHops` → Ed25519-подпись origin → seen/in-flight → адресат →
   opt-in → TTL/hop-limit → следующий хоп.
4. Следующий хоп выбирается по presence-графу и локальным линкам узла; если
   `dst` локальный, payload отдаётся в `RelayTransport.incoming`; пока у
   потока нет слушателей, кадры копятся в ограниченном буфере
   (`incomingBufferFrames`, по умолчанию 64), при переполнении новые
   отбрасываются. После отмены последнего слушателя буфер снова активен
   (R-25). Буфер не очищается до фактической доставки, поэтому `.first` не
   теряет остальные кадры; `delivered` считает отданные слушателю кадры,
   `queuedInbound` — ожидающие в буфере (R-16, R-20).
   Иначе `RelayFrame.forward()` (TTL−1, hop+1) без unknown-полей уходит
   следующему хопу.
5. `_seen` фиксируется после успешной пересылки или постановки в буфер;
   неудачная попытка снимает резерв и не блокирует запасной маршрут. При
   заполнении `seenMaxEntries` новые кадры отбрасываются (`droppedSeenFull`),
   неистёкшие записи не вытесняются (R-22). `seenMaxEntries == 0` отключает
   кэш.
6. При ошибке отправки узел теряет только relay-роль (`disableRelay`), его
   presence и прямые линки сохраняются; выбирается запасной маршрут.
   Если маршрутов нет — `RelaySendFailed(noRoute)`, доставку догоняет sync.
7. По контракту `RelayTransport` владеет `direct`: `close()` закрывает оба
   транспорта и завершает `events`/`incoming`; завершение `direct.events`
   переводит relay в `closed` без синтетических событий. Shutdown
   мемоизирован: `close()` ждёт его и закрывает `direct` ровно один раз, даже
   после `_onDirectDone` (R-18). `deliver`/`accept` повторно проверяют
   `_closed` после каждого `await` (R-17).

## Безопасность и лимиты

- Payload считается end-to-end зашифрованным выше по стеку; `core_relay` не
  содержит ключей и API расшифровки. Релей видит `src`, `dst`, `ttl`,
  `hop_count` и непрозрачные байты.
- Идентичность кадра для кэша — SHA-256(`src || dst || nonce`) через
  `package:cryptography`. Окно дедупа `seenTtl` (5 мин) считается по
  монотонным часам (`Stopwatch`), wall-clock остаётся для token bucket
  (R-23). Дедуп best-effort: после истечения окна повтор снова принимается.
  Для group-sync replay закрывает собственный дедуп `core_sync`; остальные
  payload обязаны иметь свой идентификатор.
- Token bucket на `from`: `perSourceBurstBytes` и `perSourceBytesPerSecond`;
  списывается фактический размер принятых байт до парсинга. Число bucket'ов и
  cardinality метрик ограничены LRU (`maxSourceEntries`, `maxTrackedSources`).
- `maxFrameBytes` ограничивает кадр целиком, `maxPayloadBytes` — payload внутри;
  по умолчанию `perSourceBurstBytes >= maxFrameBytes`.
- `nextHop == src/from/local` и повторный кадр отбрасываются как петля.
- Origin подписывает `(domain, src, dst, nonce(16), originTtl = ttl + hopCount,
  payload)`. Nonce случаен, входит в seen-ключ и не зависит от часов.
  Подпись обязательна; unsigned/неверная подпись даёт `droppedBadSignature`.
  `ttl/hopCount` по отдельности не подписаны: релей может их перераспределить,
  но не увеличить сумму или `maxHops`.
- `RelayEnvelope` v3 отделяет relay-кадры и отвергает v1/v2/нетэгированные байты
  (`droppedMalformed`); основной разделитель — отдельный `PeerChannels.relay`.
- `relayEnabled = false` по умолчанию и управляет только пересылкой чужих
  кадров (`accept` → `forward`). Исходящая доставка через выбранного релея от
  opt-in не зависит: отправитель всегда может использовать общий маршрут.
  Включение пересылки — через `RelayOptIn` и `relayOptInProvider` в DI.

## Медиа

Медиа не идёт через `RelayFrame`: аудио/видео пересылается топологией слоя 13
(`MediaTopology`), где релейный узел может быть выбран как media-forwarder.
`core_relay` отвечает только за сигнальные/данные кадры и не буферизует медиа.

## Ревью 2026-10-24 и исправления 2026-10-25

Границы `core_*` не нарушены, криптопримитивы не добавлялись, payload не
расшифровывается. Закрыты `R-01`–`R-09`: аутентификация первого хопа и
ключевание лимитов по `from`, LRU-границы, единые размеры, bucket до парсинга,
учёт unknown-полей, seen после успеха и in-flight, проброс ошибок
`MemberRelay`, relay-тег и opt-in default. Тесты (21) и `dart analyze` чисты.
R-11: `applyPresence`/`announce` применяют только более новый `updatedAt`, а
будущие метки ограничивают локальным временем получения, а `announce`
копирует `neighbors` в unmodifiable-set; старый presence не откатывает
маршруты и снятую relay-роль.
R-12–R-15 закрыты: буферизация `incoming` с лимитом, владение `direct` и
закрытие потоков, fingerprint через `package:cryptography`, документированное
окно seen-кэша, усиленные тесты и синхронизированный порядок проверок.
Повторное ревью 2026-10-25 блокеров не выявило; остаточные R-16–R-27
закрыты: буфер не очищается до доставки, delivered/queued и счётчики
overflow/no-buffer/closed разделены, shutdown мемоизирован, при полном seen
новые кадры отбрасываются, TTL по монотонным часам, ошибки не-awaited
`accept` учитываются, добавлены тесты порядка/повторной подписки/close и
real-Ed25519 auth.

## Решения poll (2026-10-25)

| Вопрос | Решение |
|---|---|
| Сбой прямого линка в `accept` | оставить как есть: топология не меняется, повторный `directTimeout` приемлем |
| Восстановление после `disableRelay` | до следующего presence-анонса, без TTL/backoff |
| Область `attempted` | per-frame перебор; relay-роль снимается глобально в локальной топологии |
| Метрика исчерпания | добавлен `forwardExhausted` на кадр при исчерпании альтернатив в `accept` |
| Границы R-10 | закрыто в R-12: буфер `incoming`, без synthetic `'closed'`, `close()` закрывает `direct` |
| Будущий `at` | clamp до локального времени получения |
| Равный `updatedAt` | игнорировать (строгая монотонность) |
| `disableRelay` | не двигает `updatedAt`; ждать более новый presence |
| `neighbors` в `announce` | unmodifiable-копия, как в `applyPresence` |

## Решения poll по готовности Layer-9 (2026-10-25)

| Вопрос | Решение |
|---|---|
| ACK на уровне релея | Не вводим. `RelayedSent` означает передачу следующему хопу; потерю догоняет `core_sync`. |
| RTT/load в production | Реализовано: RTT из `PeerLinkStats` через `RelayTransport.linkStats`, нагрузка — наблюдаемая скорость `RelayMetrics.observedLoadBytesPerSecond`; presence-кодек не расширяем. |
| Линки, установленные до `RelayTransport` | Реализовано: `RelayTransport.initialLocalNeighbors` → `RelayTopology.seedLocalNeighbors`, дальше обновлять из `direct.events`. |
| Семантика `maxHops` | `maxHops` — бюджет `originTtl`; второй релей допустим только как failover в `accept`. |
| Гарантия E2E | Ответственность вызывающего слоя; `core_relay` не содержит ключей и не проверяет формат ciphertext. |

## Решения poll по наблюдениям (2026-10-26)

| Вопрос | Решение |
|---|---|
| Нагрузка кандидата | Наблюдаемая скорость пересылки от этого source; удалённая нагрузка недоступна без изменения presence. |
| RTT в production | `linkStats` callback; подключён в DI через `Transport.statsFor` (`WebRtcTransport.linkFor(...).stats`). |
| Seed при смене local peer | Только при создании транспорта; повторный `setLocalPeer` очищает seeded-линки. |
| Окно нагрузки | 10 с, константа `RelayMetrics`; в `RelayConfig` не выносим. |
| Нулевой RTT | Не считается измерением, используется presence-RTT. |

## Решения poll по linkStats в DI (2026-10-26)

| Вопрос | Решение |
|---|---|
| Размещение `statsFor` | Метод `Transport.statsFor(PeerId)` с default `null`; отдельный `LinkStatsSource` не вводим. |
| Семантика `statsFor` | `null` — измерений нет; `RTT == 0` не считается измерением. |
| Частота обновления RTT | Только в `_observeTopology` при `deliver`/`accept`; события `'stats'` не подписываются. |
| `RelayTransport.statsFor` | Делегирует `direct`; собственные relay-метрики не смешиваются с RTT. |
| `FakeTransport.statsFor` | Отдаёт `stats` fake-линков, как `WebRtcTransport`. |
| `transportProvider` | Production: `WebRtcTransport` по группе (тема из `GroupSecret`); `RelayTransport` получает non-closing обёртку, владелец — провайдер транспорта. |
| Смена `transportProvider` | `relayLinkStatsProvider` использует `watch`: callback и relay пересоздаются вместе с транспортом. |

## Решения poll 2026-10-26 (opt-in и presence)

| Вопрос | Решение |
|---|---|
| Opt-in и исходящий relay | Отправка через релей доступна всегда; `relayEnabled` управляет только пересылкой чужих кадров. |
| `neighbors` в production | `WebRtcTransport` публикует connected/disconnected direct-линки через `NeighborAnnouncer`; DI-инициализация может быть пустой. |

## Остаточное

Relay-кадры подписаны и идут по отдельному `PeerChannels.relay`;
`RelayTransport` сам подписывается на `relayIncoming` и вызывает `accept`.
Presence в DI наполняет `RelayTopology` только из `RichSignalingChannel.presence`,
то есть после Ed25519-проверки конверта (Q37). Остатки повторного ревью
R-16–R-27 закрыты.
