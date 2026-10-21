import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:test/test.dart';
import 'package:core_domain/core_domain.dart';
import 'package:platform_android/platform_android.dart';

/// Mock [FlutterSecureStorage] для тестов без реального Keystore.
///
/// Реализует только методы, используемые [NativeSecureKeyStoreImpl]:
/// write / read / delete. Остальные методы интерфейса — stub.
class _MockFlutterSecureStorage implements FlutterSecureStorage {
  final _store = <String, String>{};
  final _listeners = <String, List<void Function(String?)>>{};

  @override
  final IOSOptions iOptions = IOSOptions.defaultOptions;

  @override
  final AndroidOptions aOptions = AndroidOptions.defaultOptions;

  @override
  final LinuxOptions lOptions = LinuxOptions.defaultOptions;

  @override
  final WindowsOptions wOptions = WindowsOptions.defaultOptions;

  @override
  final WebOptions webOptions = WebOptions.defaultOptions;

  @override
  final MacOsOptions mOptions = MacOsOptions.defaultOptions;

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _store[key];
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _store.containsKey(key);
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map.unmodifiable(_store);
  }

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.clear();
  }

  @override
  void registerListener({
    required String key,
    required void Function(String?) listener,
  }) {
    _listeners[key] = [...(_listeners[key] ?? []), listener];
  }

  @override
  void unregisterListener({
    required String key,
    required void Function(String?) listener,
  }) {
    final listenersForKey = _listeners[key];
    if (listenersForKey == null || listenersForKey.isEmpty) {
      return;
    }
    listenersForKey.remove(listener);
    _listeners[key] = listenersForKey;
  }

  @override
  void unregisterAllListenersForKey({required String key}) {
    _listeners.remove(key);
  }

  @override
  void unregisterAllListeners() {
    _listeners.clear();
  }

  @override
  Future<bool?> isCupertinoProtectedDataAvailable() async => null;

  @override
  Stream<bool>? get onCupertinoProtectedDataAvailabilityChanged => null;
}

T okValue<T, E>(Result<T, E> result) {
  expect(result.isOk, isTrue, reason: 'expected Ok, got $result');
  return (result as Ok<T, E>).value;
}

E errValue<T, E>(Result<T, E> result) {
  expect(result.isErr, isTrue, reason: 'expected Err, got $result');
  return (result as Err<T, E>).error;
}

IdentityBundle _bundle({
  String publicKey = 'pk-mock',
  List<int>? privateSeed,
  int createdAt = 1000,
}) =>
    IdentityBundle(
      userId: const UserId('user-mock'),
      publicKey: publicKey,
      privateSeed: privateSeed ?? [1, 2, 3],
      createdAt: createdAt,
    );

void main() {
  group('NativeSecureKeyStoreImpl (mocked FlutterSecureStorage)', () {
    late NativeSecureKeyStoreImpl store;
    late _MockFlutterSecureStorage mockStorage;

    const userId = UserId('user-mock');

    setUp(() {
      mockStorage = _MockFlutterSecureStorage();
      store = NativeSecureKeyStoreImpl(storage: mockStorage);
    });

    test('отсутствующий ключ: hasIdentity false, loadIdentity IdentityNotFound', () async {
      expect(okValue(await store.hasIdentity(userId)), isFalse);
      final err = errValue(await store.loadIdentity(userId));
      expect(err, isA<IdentityNotFound>());
    });

    test('запись и чтение IdentityBundle', () async {
      final stored = await store.storeIdentity(userId, _bundle());
      expect(stored.isOk, isTrue);
      expect(okValue(await store.hasIdentity(userId)), isTrue);
      expect(okValue(await store.loadIdentity(userId)), equals(_bundle()));
    });

    test('перезапись заменяет предыдущее значение', () async {
      await store.storeIdentity(userId, _bundle(publicKey: 'pk-1', privateSeed: [9]));
      await store.storeIdentity(userId, _bundle(publicKey: 'pk-2', privateSeed: [8]));
      expect(
        okValue(await store.loadIdentity(userId)),
        equals(_bundle(publicKey: 'pk-2', privateSeed: [8])),
      );
    });

    test('удаление удаляет запись', () async {
      await store.storeIdentity(userId, _bundle());
      expect(okValue(await store.hasIdentity(userId)), isTrue);
      final deleted = await store.deleteIdentity(userId);
      expect(deleted.isOk, isTrue);
      expect(okValue(await store.hasIdentity(userId)), isFalse);
      final err = errValue(await store.loadIdentity(userId));
      expect(err, isA<IdentityNotFound>());
    });

    test('пустое privateSeed допустимо', () async {
      final empty = _bundle(privateSeed: []);
      await store.storeIdentity(userId, empty);
      final loaded = okValue(await store.loadIdentity(userId));
      expect(loaded, equals(empty));
      expect(loaded.privateSeed, isEmpty);
    });

    test('большое значение (1 МБ) хранится и читается корректно', () async {
      final large = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 42);
      final big = _bundle(privateSeed: large);
      await store.storeIdentity(userId, big);
      expect(okValue(await store.loadIdentity(userId)), equals(big));
    });

    test('privateSeed хранится как base64 в mock-хранилище', () async {
      await store.storeIdentity(userId, _bundle(privateSeed: [1, 2, 3]));
      final raw = mockStorage._store['opensink_identity_v1_user-mock'];
      expect(raw, isNotNull);
      final map = jsonDecode(raw!) as Map<String, dynamic>;
      expect(map['privateSeed'], equals(base64Encode([1, 2, 3])));
      expect(map['schemaVersion'], equals(1));
    });

    test('неверная версия схемы при загрузке → StoreCorrupted', () async {
      await mockStorage.write(
        key: 'opensink_identity_v1_user-mock',
        value: jsonEncode({
          'userId': 'user-mock',
          'publicKey': 'pk',
          'privateSeed': base64Encode([1, 2, 3]),
          'createdAt': 1000,
          'schemaVersion': 99,
        }),
      );
      final result = await store.loadIdentity(userId);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<StoreCorrupted>());
    });

    test('повреждённый JSON при загрузке → StoreCorrupted', () async {
      await mockStorage.write(
        key: 'opensink_identity_v1_user-mock',
        value: 'not valid json',
      );
      final result = await store.loadIdentity(userId);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<StoreCorrupted>());
    });

    test('отсутствует privateSeed в записи → StoreCorrupted', () async {
      await mockStorage.write(
        key: 'opensink_identity_v1_user-mock',
        value: jsonEncode({
          'userId': 'user-mock',
          'publicKey': 'pk',
          'createdAt': 1000,
          'schemaVersion': 1,
        }),
      );
      final result = await store.loadIdentity(userId);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<StoreCorrupted>());
    });
  });
}
