import 'package:meta/meta.dart';

/// Источник captura экрана (платформенный: MediaProjection на Android,
/// wlr-screencopy / PipeWire на Linux, getDisplayMedia на Web).
abstract class ScreenCaptureSource {
  /// Поток кадров экрана (RAW RGBA или инкапсулированный видеопоток).
  Stream<List<int>> get frames;

  /// Поток аудио экрана (если поддерживается).
  Stream<List<int>>? get audioFrames;

  /// Запустить captura.
  Future<void> start();

  /// Остановить captura.
  Future<void> stop();

  bool get isCapturing;
}
