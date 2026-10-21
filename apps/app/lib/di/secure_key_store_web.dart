import 'package:core_domain/core_domain.dart';
import 'package:platform_web/platform_web.dart';

/// Фабрика SecureKeyStore для Web.
///
/// Хранилище: IndexedDB. KEK — AES-GCM-256 CryptoKey с extractable: false,
/// создаётся через Web Crypto API SubtleCrypto.generateKey.
SecureKeyStore createPlatformSecureKeyStore() => WebSecureKeyStoreImpl();
