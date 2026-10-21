import 'package:core_domain/core_domain.dart';
import 'package:platform_android/platform_android.dart';

/// Фабрика SecureKeyStore для платформ с dart:io (Android, Linux).
///
/// Обе платформы используют flutter_secure_storage. На Android — Keystore
/// (StrongBox при наличии), на Linux — libsecret / secret-service.
SecureKeyStore createPlatformSecureKeyStore() => NativeSecureKeyStoreImpl();
