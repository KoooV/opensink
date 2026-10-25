# core_relay

## Назначение

Прозрачная доставка, когда прямое WebRTC-соединение не установилось: `Transport`
сначала пробует прямой линк, затем один промежуточный сосед (A–C–B).

## Состав

- `RelayTopology` — граф из presence-анонсов (`neighbors`, `canRelay`, ёмкость,
  RTT, нагрузка). Устаревшие анонсы и `canRelay=false` не участвуют в выборе.
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
   тег/заголовок → `src == local` → `src == from` на первом хопе →
   Ed25519-подпись origin → `originTtl <= maxHops` → seen/in-flight → адресат →
   opt-in → TTL/hop-limit → следующий хоп.
4. Если `dst` локальный, payload отдаётся в `RelayTransport.incoming`.
   Иначе `RelayFrame.forward()` (TTL−1, hop+1) без unknown-полей уходит
   следующему хопу.
5. `_seen` фиксируется только после успешной доставки/пересылки; неудачная
   попытка не блокирует запасной маршрут. `seenMaxEntries == 0` отключает кэш.
6. При ошибке отправки узел теряет только relay-роль (`disableRelay`), его
   presence и прямые линки сохраняются; выбирается запасной маршрут.
   Если маршрутов нет — `RelaySendFailed(noRoute)`, доставку догоняет sync.

## Безопасность и лимиты

- Payload считается end-to-end зашифрованным выше по стеку; `core_relay` не
  содержит ключей и API расшифровки. Релей видит `src`, `dst`, `ttl`,
  `hop_count` и непрозрачные байты.
- Идентичность кадра для кэша — SHA-256(`src || dst || payload`), TTL кэша 5 мин.
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
- `relayEnabled = false` по умолчанию; включение — только через opt-in
  (`RelayOptIn` и `relayOptInProvider` в DI).

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
Остаточные пункты `R-11`–`R-15` — в `docs/DEFECTS.md`, раздел «Релей».

## Решения poll (2026-10-25)

| Вопрос | Решение |
|---|---|
| Сбой прямого линка в `accept` | оставить как есть: топология не меняется, повторный `directTimeout` приемлем |
| Восстановление после `disableRelay` | до следующего presence-анонса, без TTL/backoff |
| Область `attempted` | per-frame перебор; relay-роль снимается глобально в локальной топологии |
| Метрика исчерпания | добавлен `forwardExhausted` на кадр при исчерпании альтернатив в `accept` |
| Границы R-10 | буферизация `incoming`, synthetic `'closed'` и `close()` — в R-12 |

## Остаточное

Relay-кадры подписаны и идут по отдельному `PeerChannels.relay`;
`RelayTransport` сам подписывается на `relayIncoming` и вызывает `accept`.
Presence в DI наполняет `RelayTopology` только из `RichSignalingChannel.presence`,
то есть после Ed25519-проверки конверта (Q37).
