/// Лимиты протокола OpenSink.
///
/// Жёсткие ограничения защищают от повреждённых или злонамеренных фреймов:
/// защита от zip-bomb-подобных вложений, ограничение аллокаций при фуззинге,
/// чанкование крупных сообщений.
class ProtocolLimits {
  ProtocolLimits._();

  /// Текущая версия протокола (пишем конверты именно этой версии).
  static const int currentVersion = 1;

  /// Минимальная поддерживаемая версия (для прямой совместимости старых узлов).
  static const int minSupportedVersion = 1;

  /// Максимальная версия, которую этот узел полностью обрабатывает.
  ///
  /// Конверты с version > maxSupportedVersion декодируются структурно
  /// (прямая совместимость и пересылка релеем), но не передаются на
  /// семантическую обработку ([Envelope.isProcessable] == false).
  static const int maxSupportedVersion = currentVersion;

  /// Максимальный размер одного энвелопа (фрейма) в байтах.
  static const int maxFrameSize = 1024 * 1024; // 1 MiB

  /// Максимальный размер payload внутреннего сообщения в байтах.
  static const int maxPayloadSize = 512 * 1024; // 512 KiB

  /// Максимальный размер одного чанка файла.
  static const int maxChunkSize = 256 * 1024; // 256 KiB

  /// Максимальная длина varint в байтах (64-битное значение помещается в 10).
  static const int maxVarintBytes = 10;

  /// Максимальная глубина вложенности (защита от рекурсии).
  static const int maxNestingDepth = 64;

  /// Максимальное число полей в одном сообщении.
  static const int maxFieldsPerMessage = 1024;

  /// Максимальная длина строки в байтах (UTF-8).
  static const int maxStringBytes = 64 * 1024;

  /// Максимальное число повторов (repeated) одного поля.
  static const int maxRepeatedItems = 4096;

  /// Максимальный размер подписи Ed25519 в байтах.
  static const int maxSignatureBytes = 128;

  /// Максимальный размер идентификатора узла (открытый ключ Ed25519).
  static const int maxPeerIdBytes = 64;
}
