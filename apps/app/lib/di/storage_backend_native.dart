import 'dart:io';

import 'package:core_storage/core_storage.dart';
import 'package:platform_android/platform_android.dart';
import 'package:platform_linux/platform_linux.dart';

/// Постоянная SQLite для Android/Linux через платформенные фабрики.
StorageBackend createPlatformStorageBackend() {
  if (Platform.isAndroid) return AndroidDatabaseFactory();
  return LinuxDatabaseFactory();
}
