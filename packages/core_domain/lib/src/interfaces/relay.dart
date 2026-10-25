import '../models/identifiers.dart';
import 'package:meta/meta.dart';

/// Кадр для пересылки через релей.
@immutable
class RelayFrame {
  const RelayFrame({
    required this.src,
    required this.dst,
    required this.payload,
  });

  /// Origin кадра; локальный адаптер не вправе подписываться за чужой origin.
  final PeerId src;
  final PeerId dst;
  final List<int> payload;
}

/// Релей: маршрутизация сообщений через доверенных участников группы.
abstract class Relay {
  /// Возвращает true, если релей знает маршрут к dst.
  bool routes(PeerId dst);

  /// Пересылает кадр получателю (возможно через промежуточных релеев).
  Future<void> forward(RelayFrame frame);

  /// Текущая пропускная способность (сообщений в секунду / байт в секунду —
  /// зависит от реализации).
  int get capacity;

  /// Закрывает релей.
  Future<void> close();
}
