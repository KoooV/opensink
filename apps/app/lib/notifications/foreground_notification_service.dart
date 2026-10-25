import 'package:core_domain/core_domain.dart';

import 'foreground_state.dart';

/// Выбирает канал уведомления по видимости приложения.
///
/// В foreground показывается только in-app, чтобы OS-уведомление не
/// дублировало уже видимое сообщение. В background уведомление уходит в
/// [system] (обычно `OsNotificationService` с in-app fallback).
class ForegroundNotificationService implements NotificationService {
  ForegroundNotificationService({
    required this.foreground,
    required this.system,
    required this.inApp,
  });

  final ForegroundState foreground;
  final NotificationService system;
  final NotificationService inApp;

  @override
  Future<void> show(ChatNotification notification) async {
    if (notification.id.isEmpty) return;
    if (foreground.isForeground) {
      await inApp.show(notification);
      return;
    }
    await system.show(notification);
  }

  @override
  Future<void> cancel(String id) async {
    if (id.isEmpty) return;
    try {
      await system.cancel(id);
    } catch (_) {
      // OS-отмена не должна мешать очистке in-app состояния.
    }
    await inApp.cancel(id);
  }

  @override
  Future<void> cancelAll() async {
    try {
      await system.cancelAll();
    } catch (_) {
      // См. cancel.
    }
    await inApp.cancelAll();
  }
}
