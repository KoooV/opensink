import 'package:core_domain/core_domain.dart';
import 'package:flutter/services.dart';

/// OS-уведомления Android через нативный `NotificationManager`.
///
/// Канал `opensink/notifications` реализован в `MainActivity`. Если
/// разрешение `POST_NOTIFICATIONS` не выдано, нативный слой возвращает
/// `false`, и приложение показывает in-app fallback.
class AndroidNotificationBackend implements SystemNotificationBackend {
  AndroidNotificationBackend({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('opensink/notifications');

  final MethodChannel _channel;

  @override
  Future<bool> show(ChatNotification notification) async {
    if (notification.id.isEmpty) return false;
    try {
      final shown = await _channel.invokeMethod<bool>('show', <String, Object?>{
        'id': notification.id,
        'title': 'OpenSink',
        'body': notification.preview,
      });
      return shown ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> cancel(String id) async {
    if (id.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('cancel', <String, Object?>{'id': id});
    } on PlatformException {
      // Best-effort.
    } on MissingPluginException {
      // На платформе без нативной реализации.
    }
  }

  @override
  Future<void> cancelAll() async {
    try {
      await _channel.invokeMethod<void>('cancelAll');
    } on PlatformException {
      // Best-effort.
    } on MissingPluginException {
      // На платформе без нативной реализации.
    }
  }
}
