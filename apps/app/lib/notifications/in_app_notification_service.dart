import 'dart:async';

import 'package:core_domain/core_domain.dart';

/// Уведомления внутри приложения.
///
/// Поток используется host-виджетом, который показывает сообщения поверх UI.
/// Системные (OS) уведомления подключаются отдельной платформенной
/// реализацией за тем же [NotificationService].
class InAppNotificationService implements NotificationService {
  final Map<String, ChatNotification> _active = <String, ChatNotification>{};
  final StreamController<ChatNotification> _incoming =
      StreamController<ChatNotification>.broadcast();

  Stream<ChatNotification> get incoming => _incoming.stream;

  List<ChatNotification> get active =>
      List<ChatNotification>.unmodifiable(_active.values);

  @override
  Future<void> show(ChatNotification notification) async {
    if (notification.id.isEmpty) return;
    _active[notification.id] = notification;
    _incoming.add(notification);
  }

  @override
  Future<void> cancel(String id) async {
    _active.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    _active.clear();
  }

  Future<void> close() async {
    _active.clear();
    await _incoming.close();
  }
}
