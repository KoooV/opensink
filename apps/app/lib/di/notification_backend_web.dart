import 'package:core_domain/core_domain.dart';
import 'package:platform_web/platform_web.dart';

/// OS-уведомления для Web (Web Notifications API).
SystemNotificationBackend createPlatformNotificationBackend() {
  return WebNotificationBackend();
}
