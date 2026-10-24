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
   `rttMs + load / capacity * 1000`, отправляется `RelayFrame`.
3. Промежуточный узел принимает кадр в `accept(from, bytes)` и проверяет:
   размер → заголовок → адресата → opt-in → TTL/hop-limit → кэш петель →
   лимит источника → следующий хоп.
4. Если `dst` локальный, payload отдаётся в `RelayTransport.incoming`.
   Иначе `RelayFrame.forward()` (TTL−1, hop+1) уходит следующему хопу.
5. При ошибке отправки релея он удаляется из топологии, выбирается запасной.
   Если маршрутов нет — `RelaySendFailed(noRoute)`, доставку догоняет sync.

## Безопасность и лимиты

- Payload считается end-to-end зашифрованным выше по стеку; `core_relay` не
  содержит ключей и API расшифровки. Релей видит `src`, `dst`, `ttl`,
  `hop_count` и непрозрачные байты.
- Идентичность кадра для кэша — SHA-256(`src || dst || payload`), TTL кэша 5 мин.
- Token bucket на источник: `perSourceBurstBytes` и
  `perSourceBytesPerSecond`; превышение даёт `droppedRateLimited`.
- `nextHop == src/from/local` и повторный кадр отбрасываются как петля.

## Медиа

Медиа не идёт через `RelayFrame`: аудио/видео пересылается топологией слоя 13
(`MediaTopology`), где релейный узел может быть выбран как media-forwarder.
`core_relay` отвечает только за сигнальные/данные кадры и не буферизует медиа.

## Ревью 2026-10-24

Проведено общее и крипто/протокольное ревью диффа. Границы `core_*` не нарушены,
криптопримитивы не добавлялись, payload не расшифровывается, `forward()` не меняет
`src/dst/payload`. Тесты (11) и `dart analyze` проходят, но production-готовность
не подтверждена: открыты blocker `R-01` (неаутентифицированный `src`) и majors
`R-02`–`R-09` (лимиты/размеры, кэш, `MemberRelay`, отсутствие relay-канала,
opt-in default). Полный список — `docs/DEFECTS.md`, раздел «Релей».

## Остаточное

Production-интеграция: входящий канал `relay` в `core_peer` должен вызывать
`RelayTransport.accept`, а presence — `RelayTopology.applyPresence` (Q2).
