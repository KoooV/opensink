# core_signaling — design doc

## 1. Цель и границы

Слой реализует две независимые `SignalingChannel` с общим защищённым payload-форматом:

- `NostrSignaling` — пул публичных Nostr-реле, события ephemeral-диапазона;
- `TrackerSignaling` — пул WebSocket-трекеров в стиле WebTorrent.

Оба канала работают параллельно как пул: верхний слой (core_peer) может держать оба и
дедуплицировать сообщения по `(from, nonce)`. Внутри каждого канала пул реле также
дедуплицирует входящие. Пакеты `core_*` остаются чистым Dart: WebSocket подключается
через `package:web_socket`, который сам делает conditional import (`dart:io`/`dart:js_interop`)
внутри платформенного пакета; в `core_signaling/lib` запрещённых импортов нет.

## 2. Внутренний формат (единый для Nostr и трекеров)

Все наружные payload-ы — `SecureSignalingCodec`:

```
"OSSG" | version(2) | kind(1) | flags(1)
sender(32) | recipient(32, нули = broadcast)
timestamp_ms(2 x u32 BE) | nonce(16)
ciphertext_len(u32 BE) | ciphertext | signature(64)
```

- `signature` — Ed25519 identity отправителя над всеми байтами до подписи.
- `ciphertext` — XChaCha20-Poly1305 (ключ `GroupSecret.signalingPayloadKey()`),
  AAD = `"opensink/5/signaling/v2|" || topic_len(u32 BE) || topic(utf8) ||
  header(95 байт, без ciphertext_len)`. Topic привязан к AAD: пакет, валидный
  для одной темы, не расшифруется в другой (cross-topic replay).
- `timestamp_ms` пишется двумя 32-битными половинами: `dart2js` не поддерживает
  `ByteData.setInt64/getInt64`. Unix-ms неотрицателен и помещается в JS-safe
  integer.
- plaintext = `version(2) | body_len(u32) | body`.
- `kind`: `hello`, `offer`, `answer`, `ice`, `hangup`, `data`.
- Проверки до применения: размер, магия/версия, Ed25519-подпись, отправитель
  авторизован (`allowedPeers`/`isAuthorized`; по умолчанию авторизация = владение
  `group_secret`), адресат (broadcast или self), окно времени, replay по
  `(sender, nonce)`, rate limit. Любая ошибка — тихий `RejectReason`, без исключений.
- `hello` содержит `platform`, `publicIpv6`, `uptime`, `canRelay`, `canSfu`,
  `neighbors` и публикуется раз в `helloInterval` (по умолчанию 20 с).

## 3. Nostr (NIP-01)

- kind `21000` — ephemeral (`20000..29999`, реле не обязаны хранить/пересылать).
- Тег `["t", sha256_hex(topic)]`; подписка:
  `["REQ", subId, {"kinds":[21000],"#t":[tag],"since":now-60}]`.
- Событие: `{id, pubkey, created_at, kind, tags, content, sig}`.
  `id = sha256(utf8(JSON.stringify([0,pubkey,created_at,kind,tags,content])))`;
  `sig` — BIP-340 Schnorr (`package:bip340`) одноразовым secp256k1-ключом сессии.
- Публикация: `["EVENT", event]`; приём: `["EVENT", subId, event]`, `["EOSE", subId]`,
  `["OK", id, ok, msg]`, `["NOTICE", msg]`, `["CLOSED", subId, msg]`.
- Реальная аутентификация — внутренний Ed25519-конверт; secp-подпись нужна только
  реле. Одноразовый secp-ключ живёт в памяти сессии и не сохраняется.
- Дедупликация по `event.id` до проверки конверта (DoS) и повторно по nonce.

## 4. WebSocket-трекеры (WebTorrent)

Проверено по `bittorrent-tracker/lib/client/websocket-tracker.js` и `server.js`:
`info_hash`/`peer_id`/`offer_id`/`to_peer_id` — 20-байтовые binary strings в JSON
(по одному char code на байт), `offer`/`answer` — `{type, sdp}`.

- `info_hash = sha256(topic)[0..19]`; `peer_id = sha256(peerId.publicKey)[0..19]`.
- `join`: `announce` с `event=started`, `numwant`, `offers[]`; затем
  периодический `event=update` с hello-offer.
- `publish` без адреса: тот же конверт в `offers[].offer.sdp` (broadcast через
  несколько случайных peer-ов). `publishTo`: `answer` + `to_peer_id` — адресная
  доставка конкретному peer-у (трекер это поддерживает; `offer_id` случайный).
- SDP-поле содержит `opensink:1:<base64url(конверт)>`.
- `offer_id` — случайные 20 байт. Сервер `bittorrent-tracker` (проверено по
  `server.js` на `master`, 2026-10-23) не сверяет `offer_id` с выданными ранее и
  маршрутизирует `answer` по `to_peer_id`; поэтому случайный `offer_id` принимается
  сервером. Наш клиент при приёме `offer_id` не использует.
- TODO(verify): поведение сторонних трекеров при не-SDP `sdp`; при необходимости
  заменить `answer`-маршрут на реальный WebRTC offer/answer, оставив наш конверт в
  отдельном поле, если конкретный трекер его ретранслирует. Стандартный
  WebTorrent-клиент не поймёт `opensink:` SDP и проигнорирует такой offer/answer.

## 5. Пул, backoff, health

- Список реле = invitation relays + default relays, дедуп, максимум 5 (минимум не
  форсируется: если доступно меньше — работаем с доступными).
- Параллельная публикация во все подключённые реле; ошибка одного не отменяет
  остальные.
- Reconnect: `min(max, base * 2^failures)` + jitter ±25 %, отдельный таймер на реле.
- Health score `[0,1]`: +0.08 за сообщение, +0.20 за успешный connect, -0.25 за
  разрыв/ошибку. Наружу отдаётся снимок `RelayHealth`.
- Дедупликация Nostr — LRU/TTL по event id; трекеров — по nonce конверта.
- `SignalingChannelPool` объединяет Nostr + трекеры: publish во все каналы,
  входящие дедуплицируются по `(topic, kind, from, recipient, sha256(body))`
  с TTL. Ошибка одного backend-канала не отменяет публикацию/join в остальные;
  `close` закрывает все каналы, даже если один из них бросил исключение.

## 6. Критерии приёмки

1. Два клиента с общим `GroupSecret` через fake Nostr-реле находят друг друга и
   обмениваются SDP в обе стороны.
2. То же через fake WebTorrent-трекер.
3. Отказ одного из 3 реле не мешает обнаружению и обмену.
4. Дубликаты с нескольких реле дают ровно одно входящее сообщение.
5. Replay (повтор пакета/события) и пакеты с чужим/невалидным Ed25519 отклоняются.
6. Rate limit ограничивает входящий поток; `dart analyze` и `dart test` зелёные;
   `tool/check_core_imports.sh` не находит dart:io/dart:html в `core_signaling/lib`.
7. Пакет, зашифрованный для topic A, отклоняется при открытии в topic B.
8. Web-путь проходит в Chrome (dart2js и dart2wasm) на
   `package:web_socket` fake-реле: presence и SDP обмениваются без dart:io.

## 7. Зафиксированные решения (poll владельца, 2026-10-23, два раунда)

| Вопрос | Решение |
|---|---|
| Авторизация отправителя | `GroupSecret` = членство; опционально `allowedPeers` / `isAuthorized`. Отдельный путь для держателя invite без `group_secret` отложен. |
| Публичные реле/трекеры по умолчанию | Оставляем публичный список + `TODO(verify)` на актуальность; invitation-реле приоритетнее. |
| Наш конверт в поле `sdp` WebTorrent | Оставляем `opensink:1:base64url` в `sdp` + `TODO(verify)` на реальных трекерах. |
| Канонический NIP-01 JSON | Проверено сейчас: interop-тест с V8 `JSON.stringify` через Node.js — `test/nostr_json_interop_test.dart`. |
| LAN/QR | Вне этого слоя; отдельная будущая задача. |
| hello / presence TTL | 20 с / 60 с по умолчанию. |
| Rate limit | 40 burst / 20 в сек глобально; per-sender 20 burst / 10 в сек. |
| Дедупликация `SignalingChannelPool` | `(topic, kind, from, recipient, sha256(body))`, TTL 5 минут. Повторный идентичный SDP в этом окне считается дубликатом. |
| Держатель инвайта без `group_secret` | Отложено; текущая авторизация = владение `GroupSecret`. |
| NIP-42 AUTH | Отложено + `TODO(verify)`; использовать реле, разрешающие запись без AUTH. |
| Cross-topic replay | `topic` включён в AAD, wire format v2; тест `rejects packet moved to another topic`. |
| Список соседей в hello | caller-supplied; signaling не ведёт топологию. |
| Web-тесты | `test/signaling_web_test.dart` в Chrome на dart2js и dart2wasm; fake-реле на `package:web_socket/testing.dart`. |
| Replay-кэш | In-memory, TTL 5 минут; после рестарта процесса окно сбрасывается. |
| Health-score | Старт 0.0; растёт после connect/сообщений, падает при разрыве/ошибке. |

## 8. Остаётся открытым

Полный список с критериями закрытия — `docs/OPEN_QUESTIONS.md`, Q35.
Кратко:

- **SIG-OPEN-01** — держатель инвайта без `group_secret` (deferred).
- **SIG-OPEN-02** — актуальность/политика публичных Nostr-реле (NIP-11) и
  WebTorrent-трекеров (`TODO(verify)`).
- **SIG-OPEN-03** — NIP-42 AUTH для реле, требующих авторизацию на запись
  (deferred).
- **SIG-OPEN-04** — поведение реальных трекеров при не-SDP `sdp`;
  принятый риск — `answer`/`to_peer_id` (accepted-risk).
- **SIG-OPEN-05** — реальный браузерный `WebSocket.connect` в CI; текущие
  web-тесты используют fake-реле на `package:web_socket/testing.dart`.
- **SIG-OPEN-06** — LAN/QR реализации `SignalingChannel` (вне этого слоя).
- **SIG-OPEN-07** — персистентность replay-кэша (сейчас in-memory 5 минут,
  accepted-risk).
- **SIG-OPEN-08** — hardening `NostrEphemeralSigner` (приватный ключ не должен
  попадать в публичный API/логи; zeroization в Dart не гарантируется).

Гарантия broadcast всем peer-ам у WebTorrent-трекеров не обеспечивается;
повторные hello/offer — ответственность верхнего слоя.
