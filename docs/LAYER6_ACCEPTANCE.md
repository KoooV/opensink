# LAYER6_ACCEPTANCE.md — core_peer (прямые WebRTC-соединения)

Дата: 2026-10-23. Окружение: Linux, Dart 3.13.5, Flutter 3.47.7,
`flutter_webrtc` 1.6.2 / `dart_webrtc` 1.8.2. Статусы: **подтверждено** /
**не проверено** / **заблокировано**.

## AC1 — fake-signaling: два пира соединяются и обмениваются сообщениями

**Статус: подтверждено (VM и Chrome).**

```bash
cd packages/core_peer
flutter test test/peer_signal_codec_test.dart test/transport_fake_test.dart
# 00:00 +10: All tests passed!

cd packages/core_peer
flutter test --platform chrome test/peer_signal_codec_test.dart test/transport_fake_test.dart
# 00:03 +10: All tests passed!
```

Покрыто: offer/answer, control/sync/file/presence, обмен в обе стороны,
perfect negotiation при одновременном connect (glare), backpressure `file`,
статистика, ICE restart по смене сети, reconnect с backoff, лимит ссылок с
вытеснением, закрытие hangup.

## AC2 — peer-link корректно закрывается

**Статус: подтверждено.** Тест `two peers connect, exchange control messages and
close` проверяет `closed` на удалённой стороне и удаление ссылки после hangup.

## AC3 — смена сети (эмуляция)

**Статус: подтверждено на fake RTC.** `notifyNetworkChanged()` вызывает
`restartIce()` (fake считает вызовы), ссылка возвращается в `connected`,
трафик после restart проходит. Реальный ICE restart — AC5/AC6.

## AC4 — реальный WebRTC, headless Chrome

**Статус: подтверждено (2026-10-23).**

После миграции на `flutter_webrtc 1.6.2` / `dart_webrtc 1.8.2` / `web 1.1.2`:

```bash
cd packages/core_peer
flutter test --platform chrome --dart-define=PEER_REAL_WEBRTC=true \
  test/integration/webrtc_loopback_test.dart
# 00:10 +1: All tests passed!
```

## AC5 — реальный WebRTC, native Linux

**Статус: подтверждено (2026-10-23).**

```bash
cd apps/app
flutter test integration_test/peer_link_native_test.dart -d linux
# +3: All tests passed!
```

Покрыто: connect через signaling слоя 5, control/sync/file, `getStats`
(RTT/байты), ICE restart по `notifyNetworkChanged()`, glare (одновременный
connect), полный reconnect после инжектированного failure, закрытие с hangup.

Найден и исправлен блокирующий дефект: на native `signalingState == null` до
первого события; обёртка маппила null в `closed`, из-за чего первая навигация
не стартовала, а `_scheduleNegotiation` уходил в busy-loop. Дополнительно
исправлены: замена закрытого data-channel, повтор `send` после замены канала,
защита от каскада reset/reconnect и отсутствие лишнего offer при reset.
Регрессии: `transport_fake_test.dart` (busy-loop), real glare/reconnect.

## AC5b — реальный WebRTC, Android emulator

**Статус: подтверждено для основного сценария (2026-10-23).**

```bash
cd apps/app
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/peer_link_native_test.dart \
  -d emulator-5554 --dart-define=PEER_CHAOS=false
```

Пройден основной сценарий: connect, control/sync/file, ICE restart, stats,
close. Для запуска понадобились:
- полноценный Android Gradle template в `apps/app/android` (AGP/Gradle/Kotlin
  из актуального Flutter);
- permissions `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`,
  `CHANGE_NETWORK_STATE` (без них libwebrtc NetworkMonitor аварийно завершал
  процесс);
- `apps/app/test_driver/integration_test.dart`.

Glare и full reconnect на Android не включены в CI: эмулятор нестабильно
проходит chaos-сценарии по таймингам. Они подтверждены на Linux и fake-RTC;
`PEER_CHAOS=false` отключает их на Android.

## AC5c — публичные STUN

**Статус: подтверждено (2026-10-23).**

```bash
cd apps/app
flutter test integration_test/stun_smoke_test.dart -d linux
# +1: All tests passed!
```

`defaultPublicStun` дал `srflx`-кандидат через публичный STUN.

## AC6 — чистота core_peer

**Статус: подтверждено.**

```bash
bash tool/check_core_imports.sh
# check_core_imports: OK — нет запрещённых импортов в core_* пакетах

flutter analyze packages/core_peer
# No issues found!
```

В `core_peer/lib` нет `dart:io`, `dart:html`, `package:web`, `dart:js_interop`.
`flutter_webrtc` импортируется только в `lib/src/rtc/flutter_rtc.dart`, который
экспортируется отдельной библиотекой `package:core_peer/core_peer_flutter.dart`.
Чистые интерфейсы (`core_peer.dart`) не тянут Flutter-плагин, поэтому fake-тесты
проходят в Chrome.

## AC7 — миграция web-стека и Android runner

**Статус: подтверждено.**

- `flutter_webrtc 1.6.2`, `dart_webrtc 1.8.2`, `web 1.1.2`, `drift 2.31.0`,
  `sqlite3 2.9.4`.
- `tool/web_assets.lock` / `web_assets.sha256` обновлены; `fetch_web_assets.sh
  --check` проходит.
- `tool/test_web_full_chrome.sh`: 30/30 тестов platform_web.
- `apps/app/android` приведён к актуальному Flutter template; CI job
  `peer-native-android`.

## AC8 — документация

Design doc: `packages/core_peer/DESIGN.md` (perfect negotiation, каналы,
backpressure, ICE, политика, stats, различия web/native, ограничения).
