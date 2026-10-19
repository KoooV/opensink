import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:core_domain/core_domain.dart';

/// SecureKeyStore для Web: Web Crypto API + IndexedDB.
///
/// Ключи хранятся в зашифрованном виде (IdentityBundle.encryptedPrivateKey).
/// Web Crypto API используется для операций с ключами (если потребуется
/// нативно генерировать/импортировать CryptoKey с extractable: false).
///
/// Слабая сторона (см. DESIGN.md):
/// - XSS крадёт ключи через JS-контекст.
/// - IndexedDB не зашифрован на диске браузера.
/// - Нет аппаратной изоляции.
class WebSecureKeyStoreImpl implements SecureKeyStore {
  WebSecureKeyStoreImpl(this._dbName);

  final String _dbName;
  html.IDBFactory? _idb;
  html.IDBDatabase? _db;
  bool _initialized = false;

  Future<void> _init() async {
    if (_initialized) return;
    _idb = html.indexedDB;
    if (_idb == null) {
      throw StateError('IndexedDB not available in this browser');
    }
    await _openDb();
    _initialized = true;
  }

  Future<void> _openDb() {
    final completer = Completer<void>();
    final request = _idb!.openDatabase(_dbName, version: 1);
    request.onUpgradeNeeded.listen((_) {
      final db = request.result as html.IDBDatabase;
      if (!db.objectStoreNames.contains('identities')) {
        db.createObjectStore('identities');
      }
    });
    request.onSuccess.listen((_) {
      _db = request.result as html.IDBDatabase;
      completer.complete();
    });
    request.onError.listen((_) => completer.completeError(request.error));
    return completer.future;
  }

  html.IDBObjectStore _store({required String mode}) {
    final transaction = _db!.transaction(['identities'], mode);
    return transaction.objectStore('identities');
  }

  String _key(UserId userId) => 'identity_${userId.value}';

  @override
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle) async {
    await _init();
    final store = _store(mode: 'readwrite');
    final completer = Completer<void>();
    final json = jsonEncode({
      'userId': bundle.userId.value,
      'publicKey': bundle.publicKey,
      'encryptedPrivateKey': base64Encode(bundle.encryptedPrivateKey),
      'createdAt': bundle.createdAt,
    });
    final request = store.putString(json, _key(userId));
    request.onSuccess.listen((_) => completer.complete());
    request.onError.listen((_) => completer.completeError(request.error));
    return completer.future;
  }

  @override
  Future<IdentityBundle?> loadIdentity(UserId userId) async {
    await _init();
    final store = _store(mode: 'readonly');
    final completer = Completer<IdentityBundle?>();
    final request = store.getObject(_key(userId));
    request.onSuccess.listen((_) {
      final result = request.result as String?;
      if (result == null) {
        completer.complete(null);
      } else {
        final map = jsonDecode(result) as Map<String, dynamic>;
        completer.complete(IdentityBundle(
          userId: UserId(map['userId'] as String),
          publicKey: map['publicKey'] as String,
          encryptedPrivateKey: base64Decode(map['encryptedPrivateKey'] as String),
          createdAt: map['createdAt'] as int,
        ));
      }
    });
    request.onError.listen((_) => completer.completeError(request.error));
    return completer.future;
  }

  @override
  Future<void> deleteIdentity(UserId userId) async {
    await _init();
    final store = _store(mode: 'readwrite');
    final completer = Completer<void>();
    final request = store.delete(_key(userId));
    request.onSuccess.listen((_) => completer.complete());
    request.onError.listen((_) => completer.completeError(request.error));
    return completer.future;
  }

  @override
  Future<bool> hasIdentity(UserId userId) async {
    final bundle = await loadIdentity(userId);
    return bundle != null;
  }
}
