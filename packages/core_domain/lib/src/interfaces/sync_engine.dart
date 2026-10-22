import '../../core_domain.dart' show EventStore;
import 'event_store.dart' show EventStore;

/// Движок синхронизации состояния поверх [EventStore].
///
/// Обеспечивает конвергенцию состояния между узлами P2P-сети.
abstract class SyncEngine {
  /// Запускает процесс синхронизации (обмен событиями с peers).
  Future<void> sync();

  /// Поток уведомлений об изменениях синхронизированного состояния.
  Stream<void> get changes;

  /// Закрывает движок.
  Future<void> close();
}
