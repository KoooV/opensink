import 'package:core_domain/core_domain.dart';

/// Уведомления через OS с in-app fallback.
///
/// Если платформа не может показать системное уведомление (нет сервиса,
/// запрет разрешения, ошибка канала), сообщение уходит в [fallback]. Один и
/// тот же [ChatNotification.id] заменяет предыдущее уведомление, поэтому
/// повторная доставка идемпотентна.
class OsNotificationService implements NotificationService {
  OsNotificationService({required this.system, required this.fallback});

  final SystemNotificationBackend system;
  final NotificationService fallback;

  @override
  Future<void> show(ChatNotification notification) async {
    if (notification.id.isEmpty) return;
    var shown = false;
    try {
      shown = await system.show(notification);
    } catch (_) {
      shown = false;
    }
    if (!shown) await fallback.show(notification);
  }

  @override
  Future<void> cancel(String id) async {
    if (id.isEmpty) return;
    try {
      await system.cancel(id);
    } catch (_) {
      // Отмена OS-уведомления не должна мешать очистке in-app состояния.
    }
    await fallback.cancel(id);
  }

  @override
  Future<void> cancelAll() async {
    try {
      await system.cancelAll();
    } catch (_) {
      // См. cancel.
    }
    await fallback.cancelAll();
  }
}
