Слой: core_protocol.

Задача: определить бинарный протокол на protobuf.
1. Envelope: version, type, sender, hlc, payload (bytes), signature. Подпись по сериализованному payload и заголовку как они переданы.
2. Типы: ChatEvent, GroupEvent, SyncRequest/SyncResponse, FileChunk/FileRequest, Presence, CallControl, RelayFrame, LeaderLease.
3. RelayFrame: dst, src, ttl, hop_count, end-to-end зашифрованный payload; промежуточный узел видит только заголовок.
4. Версионирование и прямая совместимость (неизвестные поля и типы игнорируются, но пересылаются дальше).
5. Лимиты: максимальный размер фрейма, чанкинг больших сообщений, защита от zip-bomb-подобных вложений.
6. Фасад encode/decode с валидацией и Result-типом ошибок.

Приёмка: golden-файлы, fuzz-тест декодера (мусорные входы не бросают исключений и не вызывают аллокаций больше лимита), тест совместимости «старая версия читает новую».