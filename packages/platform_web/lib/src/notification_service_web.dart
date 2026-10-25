import 'dart:js_interop';

import 'package:core_domain/core_domain.dart';
import 'package:web/web.dart' as web;

/// OS-уведомления браузера через Web Notifications API.
///
/// Разрешение запрашивается только при первом показе. Если браузер не
/// поддерживает API или пользователь запретил уведомления, `show` возвращает
/// `false`; вызывающий слой использует in-app fallback.
class WebNotificationBackend implements SystemNotificationBackend {
  final Map<String, web.Notification> _active = <String, web.Notification>{};

  @override
  Future<bool> show(ChatNotification notification) async {
    if (notification.id.isEmpty) return false;
    try {
      if (web.Notification.permission == 'denied') return false;
      if (web.Notification.permission != 'granted') {
        final granted = await web.Notification.requestPermission().toDart;
        if (granted.toDart != 'granted') return false;
      }
      _active.remove(notification.id)?.close();
      _active[notification.id] = web.Notification(
        'OpenSink',
        web.NotificationOptions(
          body: notification.preview,
          tag: notification.id,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> cancel(String id) async {
    if (id.isEmpty) return;
    _active.remove(id)?.close();
  }

  @override
  Future<void> cancelAll() async {
    for (final notification in _active.values) {
      notification.close();
    }
    _active.clear();
  }
}
