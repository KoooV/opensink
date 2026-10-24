Слой: core_crypto.

Задача:
1. Identity: Ed25519 (подпись), X25519 (обмен ключами); PeerId = публичный ключ. Опциональная резервная фраза (BIP-39).
2. SecureKeyStore с реализациями: Android/Linux — flutter_secure_storage; Web — WebCrypto с неизвлекаемыми ключами + IndexedDB. Чётко опиши, какие гарантии на каждой платформе слабее.
3. Подписанные сообщения: sign(bytes) / verify(bytes, sig, pubkey). Подписывать нужно ровно те байты, что идут по сети (protobuf недетерминирован).
4. Групповой секрет: из group_secret через HKDF выводятся topic (для signaling), ключ шифрования signaling-payload и ключ приглашений (разные контексты).
5. E2EE: личные чаты — X3DH + Double Ratchet; группы — sender keys с цепочкой и ротацией при изменении состава. Если нет проверенной Dart-библиотеки, сначала design doc с обоснованием, затем реализация.
6. AEAD: XChaCha20-Poly1305 или AES-GCM (выбери и обоснуй, учти поддержку на web).

Не делай: свои примитивы, сравнение подписей/MAC не в constant-time.
Приёмка: известные тестовые векторы, property-тесты encrypt/decrypt, тесты на подмену и replay, на web (`flutter test --platform chrome`) и native проходят одинаково.