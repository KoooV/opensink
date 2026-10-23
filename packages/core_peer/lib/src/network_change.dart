import 'dart:async';

/// Источник событий смены сети.
///
/// core_peer не использует dart:io/dart:html. Платформенная реализация
/// (connectivity_plus/native) поставляет сюда события; для тестов есть
/// [ManualNetworkChangeSource].
abstract interface class NetworkChangeSource {
  Stream<void> get changes;

  Future<void> close();
}

/// Ручной источник: тесты и platform_* вызывают [notify].
class ManualNetworkChangeSource implements NetworkChangeSource {
  final StreamController<void> _controller = StreamController<void>.broadcast(
    sync: true,
  );

  @override
  Stream<void> get changes => _controller.stream;

  void notify() {
    if (!_controller.isClosed) {
      _controller.add(null);
    }
  }

  @override
  Future<void> close() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}
