/// Заглушка SecureKeyStore удалена (фаза F4A).
///
/// Платформенная реализация находится в `platform_android` /
/// `platform_linux` / `platform_web` и подключается через DI. По умолчанию
/// провайдер `secureKeyStoreProvider` бросает ошибку при старте —
/// явное подключение обязательно.
