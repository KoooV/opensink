Слой: core_peer на flutter_webrtc.

Задача: реализация PeerLink и Transport (только прямые соединения).
1. RTCPeerConnection на пира, perfect negotiation (polite/impolite определяется сравнением PeerId), обработка glare.
2. DataChannel'ы: control (reliable, ordered), sync, file (с backpressure через bufferedAmount / bufferedAmountLowThreshold), опционально unreliable для presence.
3. ICE: список публичных STUN из конфига, IPv6-кандидаты включены, ICE restart при смене сети, таймауты.
4. Политика соединений: лимит одновременных линков, приоритет членам активных групп/каналов, переподключение с backoff.
5. Статистика линка (getStats): RTT, потери, исходящий битрейт — наружу через PeerLink.stats.
6. Обёртка над различиями flutter_webrtc на web и native; все различия описать в design doc.

Тесты: пары пиров с fake-signaling; интеграционный тест на реальном WebRTC (headless Chrome и Linux).
Приёмка: два клиента устанавливают соединение через signaling слоя 5, обмениваются сообщениями, переживают смену сети (эмуляция), корректно закрываются.