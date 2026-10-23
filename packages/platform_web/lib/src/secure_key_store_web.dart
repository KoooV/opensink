// ignore_for_file: invalid_runtime_check_with_js_interop_types
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart';
import 'package:core_domain/core_domain.dart';

/// SecureKeyStore для Web: Web Crypto API + IndexedDB через [package:web].
///
/// Дизайн (см. DESIGN.md §12):
/// - KEK — AES-GCM-256 `CryptoKey` с `extractable: false`, usages encrypt/decrypt,
///   создаётся через `SubtleCrypto.generateKey`, хранится в IndexedDB (хранилище `keys`).
/// - При `storeIdentity` `IdentityBundle` сериализуется в JSON, шифруется AES-GCM
///   (случайный 96-битный IV) с помощью KEK; AAD = имя ключа (`identity_<userId>`),
///   чтобы нельзя было подменить blob под другим именем. Пара `{version, iv, ciphertext}`
///   сохраняется в хранилище `identities`.
/// - При `loadIdentity` запись читается, расшифровывается KEK с тем же AAD,
///   десериализуется. Неверный MAC/формат → `StoreCorrupted`.
/// - `getOrCreateKek` выполняется в одной `readwrite` транзакции (add, при конфликте
///   ConstraintError — перечитать), что предотвращает создание разных KEK в двух вкладках.
///
/// Ограничения (честная оценка, см. DESIGN.md §12, таблица угроз):
/// - Защищает от чтения дампа IndexedDB (KEK не извлекается, extractable: false).
/// - Не защищает от XSS: JS с правом выполнения может использовать KEK через Web Crypto API.
/// - Неизвлекаемость самого identity-ключа (Ed25519/X25519) на web недостижима, так как
///   подпись выполняется в Dart над расшифрованным в памяти ключом.
/// - Персистентность не гарантирована без `storage.persist()`.
/// - Безопасное затирание seed из памяти Dart не гарантируется (GC может копировать Uint8List).
class WebSecureKeyStoreImpl implements SecureKeyStore {
  WebSecureKeyStoreImpl({this.dbName = 'opensink_keystore'});

  final String dbName;

  IDBDatabase? _db;
  CryptoKey? _kek;

  static const _kekStore = 'keys';
  static const _identitiesStore = 'identities';
  static const _stateKeysStore = 'state_keys';
  static const _kekKey = 'opensink_kek';
  static const _schemaVersion = 1;

  /// Запросить персистентное хранилище (navigator.storage.persist).
  /// Слой 14 вызывает этот метод при необходимости гарантировать сохранение
  /// данных между сессиями браузера.
  Future<Result<bool, KeyStoreError>> requestPersistentStorage() async {
    try {
      final storage = window.navigator.storage;
      final persisted = await storage.persist().toDart;
      return Ok(persisted.toDart);
    } on UnsupportedError catch (e) {
      return Err(StoreUnavailable(
        'Navigator storage API недоступен: $e',
      ));
    } catch (e) {
      return Err(StoreUnavailable(
        'Не удалось запросить персистентное хранилище: $e',
      ));
    }
  }

  Future<IDBDatabase> get _database async {
    _db ??= await _openDb();
    return _db!;
  }

  Future<IDBDatabase> _openDb() {
    final completer = Completer<IDBDatabase>();
    final request = window.indexedDB.open(dbName, _schemaVersion);
    request.onupgradeneeded = ((Event _) {
      final db = request.result as IDBDatabase;
      if (!db.objectStoreNames.contains(_kekStore)) {
        db.createObjectStore(_kekStore);
      }
      if (!db.objectStoreNames.contains(_identitiesStore)) {
        db.createObjectStore(_identitiesStore);
      }
      if (!db.objectStoreNames.contains(_stateKeysStore)) {
        db.createObjectStore(_stateKeysStore);
      }
    }).toJS;
    request.onsuccess = ((Event _) {
      completer.complete(request.result as IDBDatabase);
    }).toJS;
    request.onerror = ((Event _) {
      final domExc = request.error;
      completer.completeError(
        StoreUnavailable(
          'Не удалось открыть IndexedDB: ${domExc?.message ?? 'неизвестная ошибка'}',
        ),
      );
    }).toJS;
    return completer.future;
  }

  /// Получает существующий KEK или создаёт новый в одной readwrite-транзакции.
  /// Защита от гонки вкладок: две вкладки не получат разные KEK.
  Future<CryptoKey> _getOrCreateKek() async {
    if (_kek != null) return _kek!;
    final db = await _database;
    final stores = JSArray<JSString>()..add(_kekStore.toJS);
    final tx = db.transaction(stores, 'readwrite');
    final store = tx.objectStore(_kekStore);

    // Пытаемся прочитать существующий KEK.
    final existing = await _futureFromRequest<JSAny?>(
      store.get(_kekKey.toJS),
      (r) => r,
    );
    if (existing is CryptoKey) {
      _kek = existing;
      return _kek!;
    }

    // KEK отсутствует — генерируем и пытаемся добавить.
    final kek = await _generateKek();
    try {
      await _futureFromRequest<void>(
        store.add(kek, _kekKey.toJS),
        (_) {},
      );
      _kek = kek;
      return kek;
    } on DOMException catch (e) {
      // ConstraintError: другая вкладка добавила KEK первыми. Перечитываем.
      if (e.name == 'ConstraintError') {
        final retry = await _futureFromRequest<JSAny?>(
          store.get(_kekKey.toJS),
          (r) => r,
        );
        if (retry is CryptoKey) {
          _kek = retry;
          return retry;
        }
      }
      rethrow;
    }
  }

  JSObject _aesKeyGenParams() {
    return JSObject()
      ..setProperty('name'.toJS, 'AES-GCM'.toJS)
      ..setProperty('length'.toJS, 256.toJS);
  }

  JSObject _aesGcmParams(Uint8List iv, Uint8List aad) {
    return JSObject()
      ..setProperty('name'.toJS, 'AES-GCM'.toJS)
      ..setProperty('iv'.toJS, iv.toJS)
      ..setProperty('additionalData'.toJS, aad.toJS);
  }

  Future<CryptoKey> _generateKek() async {
    final promise = window.crypto.subtle.generateKey(
      _aesKeyGenParams(),
      false,
      JSArray<JSString>()
        ..add('encrypt'.toJS)
        ..add('decrypt'.toJS),
    );
    final result = await promise.toDart;
    return result as CryptoKey;
  }

  String _identityKey(UserId userId) => 'identity_${userId.value}';

  /// AAD для шифрования/расшифровки: имя ключа в байтах UTF-8.
  Uint8List _aadFor(UserId userId) => utf8.encode(_identityKey(userId));

  Future<Uint8List> _encryptAad(
    CryptoKey kek,
    Uint8List plaintext,
    Uint8List aad,
    Uint8List iv,
  ) async {
    final params = _aesGcmParams(iv, aad);
    final promise =
        window.crypto.subtle.encrypt(params, kek, plaintext.toJS);
    final result = await promise.toDart;
    return Uint8List.view((result as JSArrayBuffer).toDart);
  }

  Future<Uint8List> _decryptAad(
    CryptoKey kek,
    JSAny ciphertext,
    Uint8List aad,
    Uint8List iv,
  ) async {
    final params = _aesGcmParams(iv, aad);
    final promise = window.crypto.subtle.decrypt(
      params,
      kek,
      ciphertext as JSUint8Array,
    );
    final result = await promise.toDart;
    return Uint8List.view((result as JSArrayBuffer).toDart);
  }

  @override
  Future<Result<void, KeyStoreError>> storeIdentity(
    UserId userId,
    IdentityBundle bundle,
  ) async {
    try {
      final kek = await _getOrCreateKek();
      final identityJson = jsonEncode({
        'userId': bundle.userId.value,
        'publicKey': bundle.publicKey,
        'privateSeed': base64Encode(bundle.privateSeed),
        'createdAt': bundle.createdAt,
        'schemaVersion': _schemaVersion,
      });
      final plaintext = utf8.encode(identityJson);
      final iv = Uint8List(12);
      window.crypto.getRandomValues(iv.toJS);
      final aad = _aadFor(userId);
      final ciphertext = await _encryptAad(kek, plaintext, aad, iv);
      final ciphertextBytes = ciphertext;
      await _put(
        _identitiesStore,
        _identityKey(userId).toJS,
        jsonEncode({
          'version': _schemaVersion,
          'iv': base64Encode(iv),
          'ciphertext': base64Encode(ciphertextBytes),
        }).toJS,
      );
      return const Ok(null);
    } on StoreUnavailable catch (e) {
      return Err(e);
    } on DOMException catch (e) {
      return Err(
        StoreError(
          'Ошибка Web Crypto API/IndexedDB при сохранении: ${e.message}',
        ),
      );
    } catch (e) {
      return Err(
        StoreError('Не удалось сохранить идентичность в IndexedDB: $e'),
      );
    }
  }

  @override
  Future<Result<IdentityBundle, KeyStoreError>> loadIdentity(
    UserId userId,
  ) async {
    try {
      final kek = await _getOrCreateKek();
      final packed = await _get(_identitiesStore, _identityKey(userId).toJS);
      // ignore: unnecessary_null_comparison
      if (packed == null) {
        return const Err(IdentityNotFound());
      }
      final String packedStr;
      if (packed is String) {
        packedStr = packed as String;
      } else {
        return const Err(
          StoreCorrupted(
            'Неверный формат записи в хранилище: ожидается JSON-строка',
          ),
        );
      }
      Map<String, dynamic> map;
      try {
        map = jsonDecode(packedStr) as Map<String, dynamic>;
      } on FormatException {
        return const Err(
          StoreCorrupted('Неверный JSON в записи хранилища'),
        );
      }
      final version = map['version'];
      if (version is! int || version != _schemaVersion) {
        return Err(StoreCorrupted(
          'Неподдерживаемая версия схемы записи: $version',
        ));
      }
      final ivB64 = map['iv'] as String?;
      final ciphertextB64 = map['ciphertext'] as String?;
      if (ivB64 == null || ciphertextB64 == null) {
        return const Err(StoreCorrupted(
          'Запись хранилища не содержит iv или ciphertext',
        ));
      }
      late Uint8List iv;
      late Uint8List ciphertext;
      try {
        iv = base64Decode(ivB64);
        ciphertext = base64Decode(ciphertextB64);
      } on FormatException {
        return const Err(StoreCorrupted(
          'Неверный base64 в записи хранилища',
        ));
      }
      final aad = _aadFor(userId);
      Uint8List plaintext;
      try {
        plaintext = await _decryptAad(
          kek,
          ciphertext.toJS,
          aad,
          iv,
        );
      } on DOMException catch (e) {
        // InvalidAccessError / OperationError — неверный MAC или подделанные данные.
        return Err(StoreCorrupted(
          'Не удалось расшифровать запись (проверка MAC не пройдена): ${e.message}',
        ));
      }
      final identityJson = utf8.decode(plaintext);
      Map<String, dynamic> identityMap;
      try {
        identityMap = jsonDecode(identityJson) as Map<String, dynamic>;
      } on FormatException {
        return const Err(StoreCorrupted(
          'Расшифрованные данные не являются валидным JSON',
        ));
      }
      try {
        return Ok(
          IdentityBundle(
            userId: UserId(identityMap['userId'] as String),
            publicKey: identityMap['publicKey'] as String,
            privateSeed:
                base64Decode(identityMap['privateSeed'] as String),
            createdAt: identityMap['createdAt'] as int,
          ),
        );
      } on TypeError catch (e) {
        return Err(StoreCorrupted('Неверные типы полей в записи: $e'));
      } on FormatException {
        return const Err(StoreCorrupted(
          'Неверный base64 в privateSeed расшифрованной записи',
        ));
      }
    } on StoreUnavailable catch (e) {
      return Err(e);
    } on StoreCorrupted catch (e) {
      return Err(e);
    } on DOMException catch (e) {
      return Err(
        StoreError(
          'Ошибка Web Crypto API/IndexedDB при загрузке: ${e.message}',
        ),
      );
    } catch (e) {
      return Err(
        StoreError('Не удалось загрузить идентичность из IndexedDB: $e'),
      );
    }
  }

  @override
  Future<Result<void, KeyStoreError>> deleteIdentity(UserId userId) async {
    try {
      final db = await _database;
      final stores = JSArray<JSString>()..add(_identitiesStore.toJS);
      final tx = db.transaction(stores, 'readwrite');
      final store = tx.objectStore(_identitiesStore);
      await _futureFromRequest(
        store.delete(_identityKey(userId).toJS),
        (_) => null,
      );
      return const Ok(null);
    } on StoreUnavailable catch (e) {
      return Err(e);
    } on DOMException catch (e) {
      return Err(
        StoreError('Ошибка IndexedDB при удалении: ${e.message}'),
      );
    } catch (e) {
      return Err(
        StoreError('Не удалось удалить идентичность из IndexedDB: $e'),
      );
    }
  }

  @override
  Future<Result<bool, KeyStoreError>> hasIdentity(UserId userId) async {
    try {
      final value = await _get(_identitiesStore, _identityKey(userId).toJS);
      return Ok(value != null);
    } on StoreUnavailable catch (e) {
      return Err(e);
    } on DOMException catch (e) {
      return Err(
        StoreError('Ошибка IndexedDB при проверке наличия: ${e.message}'),
      );
    } catch (e) {
      return Err(
        StoreError(
          'Не удалось проверить наличие идентичности в IndexedDB: $e',
        ),
      );
    }
  }

  @override
  Future<Result<void, KeyStoreError>> storeKey(
    String keyId,
    List<int> bytes,
  ) async {
    try {
      await _put(
        _stateKeysStore,
        keyId.toJS,
        base64Encode(bytes).toJS,
      );
      return const Ok(null);
    } on StoreUnavailable catch (e) {
      return Err(e);
    } on DOMException catch (e) {
      return Err(
        StoreError(
          'Ошибка IndexedDB при сохранении ключа состояния: ${e.message}',
        ),
      );
    } catch (e) {
      return Err(
        StoreError(
          'Не удалось сохранить ключ состояния в IndexedDB: $e',
        ),
      );
    }
  }

  @override
  Future<Result<List<int>, KeyStoreError>> loadKey(String keyId) async {
    try {
      final value = await _get(_stateKeysStore, keyId.toJS);
      if (value == null) {
        return const Err(IdentityNotFound());
      }
      final b64 = value as String;
      return Ok(base64Decode(b64));
    } on FormatException catch (e) {
      return Err(StoreCorrupted('Неверный base64 в ключе состояния: $e'));
    } on StoreUnavailable catch (e) {
      return Err(e);
    } on DOMException catch (e) {
      return Err(
        StoreError(
          'Ошибка IndexedDB при загрузке ключа состояния: ${e.message}',
        ),
      );
    } catch (e) {
      return Err(
        StoreError(
          'Не удалось загрузить ключ состояния из IndexedDB: $e',
        ),
      );
    }
  }

  @override
  Future<Result<void, KeyStoreError>> deleteKey(String keyId) async {
    try {
      final db = await _database;
      final stores = JSArray<JSString>()..add(_stateKeysStore.toJS);
      final tx = db.transaction(stores, 'readwrite');
      final store = tx.objectStore(_stateKeysStore);
      await _futureFromRequest(
        store.delete(keyId.toJS),
        (_) => null,
      );
      return const Ok(null);
    } on StoreUnavailable catch (e) {
      return Err(e);
    } on DOMException catch (e) {
      return Err(
        StoreError(
          'Ошибка IndexedDB при удалении ключа состояния: ${e.message}',
        ),
      );
    } catch (e) {
      return Err(
        StoreError(
          'Не удалось удалить ключ состояния из IndexedDB: $e',
        ),
      );
    }
  }

  Future<JSAny?> _get(String storeName, JSAny? key) {
    final db = _database;
    return db.then((database) {
      final stores = JSArray<JSString>()..add(storeName.toJS);
      final tx = database.transaction(stores, 'readonly');
      final store = tx.objectStore(storeName);
      return _futureFromRequest(store.get(key), (r) => r);
    });
  }

  Future<void> _put(String storeName, JSAny? key, JSAny? value) {
    final db = _database;
    return db.then((database) {
      final stores = JSArray<JSString>()..add(storeName.toJS);
      final tx = database.transaction(stores, 'readwrite');
      final store = tx.objectStore(storeName);
      return _futureFromRequest(store.put(value, key), (_) {});
    });
  }

  Future<T> _futureFromRequest<T>(IDBRequest request, T Function(JSAny?) extract) {
    final completer = Completer<T>();
    request.onsuccess = ((Event _) {
      if (!completer.isCompleted) {
        completer.complete(extract(request.result));
      }
    }).toJS;
    request.onerror = ((Event _) {
      if (!completer.isCompleted) {
        final domExc = request.error;
        completer.completeError(
          StoreUnavailable(
            'Запрос IndexedDB не удался: ${domExc?.message ?? 'неизвестная ошибка'}',
          ),
        );
      }
    }).toJS;
    return completer.future;
  }
}
