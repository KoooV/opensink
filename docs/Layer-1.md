Слой: каркас монорепозитория и контракты.

Задача:
1. Создай melos-монорепо по структуре из контекста; apps/app собирается под linux, web, android с пустым экраном.
2. В core_domain определи интерфейсы и модели:
   - Identity, Signer, PeerId (публичный ключ), GroupId
   - SignalingChannel: join(topic), publish(bytes), Stream<SignalingMessage>
   - PeerLink: send(channel, bytes), Stream<Incoming>, state, stats (RTT, bytes, loss), close()
   - Transport: connect(peerId), Stream<PeerLinkEvent>, send(dst, bytes) — прозрачно выбирает прямой путь или Relay
   - Relay: routes(dst), forward(frame), capacity
   - MediaTopology: plan(participants, capabilities) -> TopologyPlan (mesh или hosted-by-peer)
   - EventStore, SyncEngine, GroupState, SecureKeyStore, ScreenCaptureSource
3. Для каждого интерфейса — in-memory fake.
4. DI на riverpod, строгие lint-правила, CI (GitHub Actions): analyze, test, сборки web / linux / apk.
5. Короткий ADR-файл: решения по структуре и именованию.

Приёмка: `melos run analyze && melos run test` зелёные; три сборки проходят; ни один core_* пакет не импортирует dart:io/dart:html.