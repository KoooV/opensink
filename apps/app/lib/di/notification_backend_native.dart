import 'dart:io';

import 'package:core_domain/core_domain.dart';
import 'package:platform_android/platform_android.dart';
import 'package:platform_linux/platform_linux.dart';

/// OS-уведомления для Android и Linux.
SystemNotificationBackend createPlatformNotificationBackend() {
  if (Platform.isAndroid) return AndroidNotificationBackend();
  return LinuxNotificationBackend();
}
