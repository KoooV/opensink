Слой: platform_android, platform_linux, platform_web.

Android:
- Foreground service (типы: microphone, mediaProjection, при необходимости connectedDevice), каналы уведомлений, разрешения (POST_NOTIFICATIONS, FOREGROUND_SERVICE_*, RECORD_AUDIO), WakeLock/WifiLock.
- Режим «постоянное соединение» (opt-in) вместо push: честно покажи в UI компромисс по батарее.
- Смена сети (ConnectivityManager) → ICE restart; запрос исключения из battery optimization; по умолчанию не ретранслировать по мобильному трафику.

Linux:
- Трей, автозапуск, режим «свёрнут как узел» (приложение остаётся в сети без окна); интеграция с xdg-desktop-portal.
- Проверка зависимостей PipeWire/PulseAudio при старте, понятные ошибки.

Web:
- Таймеры и keepalive не должны душиться в фоновой вкладке (рассмотри Web Worker); корректный leave при закрытии вкладки.
- navigator.storage.persist(), PWA-манифест, политика автовоспроизведения.
- Требования к заголовкам хостинга (COOP/COEP) — список и фолбэк.

Приёмка: чек-лист по платформам: звонок переживает сворачивание/блокировку (Android), запуск в трее (Linux), возврат на вкладку без потери состояния (Web).