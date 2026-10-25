import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'package:core_domain/core_domain.dart';

import '../crypto_exceptions.dart';
import 'double_ratchet.dart';
import 'session_store.dart';
import 'x3dh.dart';

/// Бинарный формат публичного X3DH-бандла для signaling presence.
///
/// version(1) || IK(32) || SPK(32) || Ed25519PK(32) || sigLen(1) || sig.
class X3dhBundleCodec {
  const X3dhBundleCodec();

  static const int _version = 1;
  static const int _fixedLength = 1 + 32 + 32 + 32 + 1;

  Uint8List encode(X3DHPublicBundle bundle) {
    final ik = _publicBytes(bundle.identityKey);
    final spk = _publicBytes(bundle.signedPrekey);
    final ed = _publicBytes(bundle.ed25519PublicKey);
    final signature = _signatureBytes(bundle.signedPrekeySignature);
    final out = Uint8List(_fixedLength + signature.length);
    var offset = 0;
    out[offset++] = _version;
    out.setRange(offset, offset + 32, ik);
    offset += 32;
    out.setRange(offset, offset + 32, spk);
    offset += 32;
    out.setRange(offset, offset + 32, ed);
    offset += 32;
    out[offset++] = signature.length;
    out.setRange(offset, offset + signature.length, signature);
    return out;
  }

  X3DHPublicBundle? decode(Uint8List bytes) {
    if (bytes.length < _fixedLength) return null;
    if (bytes[0] != _version) return null;
    var offset = 1;
    final ik = Uint8List.fromList(bytes.sublist(offset, offset + 32));
    offset += 32;
    final spk = Uint8List.fromList(bytes.sublist(offset, offset + 32));
    offset += 32;
    final ed = Uint8List.fromList(bytes.sublist(offset, offset + 32));
    offset += 32;
    final sigLength = bytes[offset++];
    if (offset + sigLength != bytes.length) return null;
    if (sigLength != 64) return null;
    final signature = Uint8List.fromList(bytes.sublist(offset));

    return X3DHPublicBundle(
      identityKey: crypto_pkg.SimplePublicKey(
        ik,
        type: crypto_pkg.KeyPairType.x25519,
      ),
      signedPrekey: crypto_pkg.SimplePublicKey(
        spk,
        type: crypto_pkg.KeyPairType.x25519,
      ),
      ed25519PublicKey: crypto_pkg.SimplePublicKey(
        ed,
        type: crypto_pkg.KeyPairType.ed25519,
      ),
      signedPrekeySignature: _hex(signature),
    );
  }

  Uint8List _publicBytes(crypto_pkg.PublicKey key) {
    if (key is! crypto_pkg.SimplePublicKey || key.bytes.length != 32) {
      throw ArgumentError('public key must be a 32-byte SimplePublicKey');
    }
    return Uint8List.fromList(key.bytes);
  }

  Uint8List _signatureBytes(String? signature) {
    if (signature == null) return Uint8List(0);
    final bytes = _unhex(signature);
    if (bytes == null || bytes.length != 64) {
      throw ArgumentError('signed prekey signature must be 64 bytes');
    }
    return bytes;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List? _unhex(String value) {
    if (value.length.isOdd) return null;
    final result = Uint8List(value.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      final byte = int.tryParse(value.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      result[i] = byte;
    }
    return result;
  }
}

/// Первый шаг X3DH-рукопожатия: эфемерный X25519-ключ отправителя.
class E2eHandshake {
  const E2eHandshake({required this.ephemeralPublicKey});

  final crypto_pkg.PublicKey ephemeralPublicKey;

  static const int _version = 1;

  Uint8List toBytes() {
    final key = ephemeralPublicKey;
    if (key is! crypto_pkg.SimplePublicKey || key.bytes.length != 32) {
      throw ArgumentError('ephemeral key must be a 32-byte SimplePublicKey');
    }
    final out = Uint8List(33);
    out[0] = _version;
    out.setRange(1, 33, key.bytes);
    return out;
  }

  static E2eHandshake? fromBytes(Uint8List bytes) {
    if (bytes.length != 33 || bytes[0] != _version) return null;
    return E2eHandshake(
      ephemeralPublicKey: crypto_pkg.SimplePublicKey(
        Uint8List.fromList(bytes.sublist(1)),
        type: crypto_pkg.KeyPairType.x25519,
      ),
    );
  }
}

/// Менеджер личных E2E-сессий: X3DH (IK + SPK) + Double Ratchet.
///
/// Публичный бандл предназначен для подписанного signaling presence.
/// Инициатор обязан передать ожидаемый Ed25519-ключ пира: бандл с чужим
/// ключом отклоняется до DH-вычислений.
class E2eSessionManager {
  factory E2eSessionManager({
    required X3DHKeyBundle localBundle,
    X3DH? x3dh,
    X3dhBundleCodec bundleCodec = const X3dhBundleCodec(),
    E2eSessionStore? store,
  }) {
    return E2eSessionManager._(localBundle, x3dh ?? X3DH(), bundleCodec, store);
  }

  E2eSessionManager._(
    this._localBundle,
    this._x3dh,
    this._bundleCodec,
    this._store,
  );

  final X3DHKeyBundle _localBundle;
  final X3DH _x3dh;
  final X3dhBundleCodec _bundleCodec;
  final E2eSessionStore? _store;
  final Map<String, DoubleRatchet> _sessions = <String, DoubleRatchet>{};
  final Set<String> _restored = <String>{};
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  X3DHPublicBundle get publicBundle => _localBundle.toPublicBundle();

  Uint8List encodedPublicBundle() => _bundleCodec.encode(publicBundle);

  bool hasSession(String peerId) => _sessions.containsKey(peerId);

  /// Восстанавливает сохранённую сессию пира (если она есть).
  ///
  /// Повреждённая или нерасшифровываемая запись удаляется, чтобы пиры могли
  /// установить новую сессию. Инфраструктурная ошибка хранилища — fail-closed
  /// (`SessionPersistenceFailed`).
  Future<CryptoResult<void>> restoreSession(String peerId) {
    if (peerId.isEmpty) {
      return Future<CryptoResult<void>>.value(const Err(InvalidKey()));
    }
    return _serialize(peerId, () => _restoreLocked(peerId));
  }

  Future<CryptoResult<void>> _restoreLocked(String peerId) async {
    final store = _store;
    if (store == null ||
        _sessions.containsKey(peerId) ||
        _restored.contains(peerId)) {
      return const Ok(null);
    }

    final loaded = await store.load(peerId);
    if (loaded.isErr) {
      final error = loaded.unwrapErr();
      if (error is E2eSessionStoreCorrupted) {
        await store.delete(peerId);
        _restored.add(peerId);
        return const Ok(null);
      }
      return const Err(SessionPersistenceFailed());
    }

    final state = loaded.unwrap();
    _restored.add(peerId);
    if (state == null || state.isEmpty) return const Ok(null);

    try {
      _sessions[peerId] = DoubleRatchet.fromBytes(state);
    } catch (_) {
      await store.delete(peerId);
    }
    return const Ok(null);
  }

  /// Проверяет SPK-binding публичного бандла до сохранения/инициации.
  Future<bool> verifyRemoteBundle(X3DHPublicBundle bundle) =>
      _x3dh.verifyPublicBundle(bundle);

  Future<CryptoResult<E2eHandshake>> initiate({
    required String peerId,
    required X3DHPublicBundle remoteBundle,
    required crypto_pkg.PublicKey expectedEd25519PublicKey,
  }) {
    if (peerId.isEmpty) {
      return Future<CryptoResult<E2eHandshake>>.value(const Err(InvalidKey()));
    }
    return _serialize(peerId, () async {
      final restored = await _restoreLocked(peerId);
      if (restored.isErr) return Err(restored.unwrapErr());
      if (_sessions.containsKey(peerId)) {
        return const Err(AlreadyInitialized());
      }
      if (!_sameKey(remoteBundle.ed25519PublicKey, expectedEd25519PublicKey)) {
        return const Err(InvalidSignature());
      }
      final sender = await _x3dh.sender(remoteBundle: remoteBundle);
      if (sender.isErr) return Err(sender.unwrapErr());

      final shared = sender.unwrap();
      final keys = await x3dhToSessionKeys(shared.sharedKey);
      final next = DoubleRatchet(
        rootKey: keys.rootKey,
        sendingChainKey: keys.sendingChainKey,
        receivingChainKey: keys.receivingChainKey,
      );
      final persisted = await _persist(peerId, next);
      if (persisted.isErr) return Err(persisted.unwrapErr());
      _sessions[peerId] = next;
      return Ok(E2eHandshake(ephemeralPublicKey: shared.ephemeralPublicKey));
    });
  }

  Future<CryptoResult<void>> accept({
    required String peerId,
    required Uint8List handshake,
  }) {
    if (peerId.isEmpty) {
      return Future<CryptoResult<void>>.value(const Err(InvalidKey()));
    }
    return _serialize(peerId, () async {
      final restored = await _restoreLocked(peerId);
      if (restored.isErr) return Err(restored.unwrapErr());
      if (_sessions.containsKey(peerId)) {
        return const Err(AlreadyInitialized());
      }
      final decoded = E2eHandshake.fromBytes(handshake);
      if (decoded == null) return const Err(InvalidKey());

      final shared = await _x3dh.receiver(
        bundle: _localBundle,
        senderEphemeralPublicKey: decoded.ephemeralPublicKey,
      );
      final keys = await x3dhToSessionKeys(shared);
      final next = DoubleRatchet(
        rootKey: keys.rootKey,
        sendingChainKey: keys.receivingChainKey,
        receivingChainKey: keys.sendingChainKey,
      );
      final persisted = await _persist(peerId, next);
      if (persisted.isErr) return Err(persisted.unwrapErr());
      _sessions[peerId] = next;
      return const Ok(null);
    });
  }

  Future<CryptoResult<Uint8List>> encrypt({
    required String peerId,
    required Uint8List plaintext,
    Uint8List? associatedData,
  }) {
    if (peerId.isEmpty) {
      return Future<CryptoResult<Uint8List>>.value(const Err(InvalidKey()));
    }
    return _serialize(peerId, () async {
      final restored = await _restoreLocked(peerId);
      if (restored.isErr) return Err(restored.unwrapErr());
      final ratchet = _sessions[peerId];
      if (ratchet == null) return const Err(SessionUnavailable());
      final result = await ratchet.encrypt(
        plaintext: plaintext,
        associatedData: associatedData,
      );
      if (result.isErr) return Err(result.unwrapErr());
      final next = result.unwrap().nextState;
      final persisted = await _persist(peerId, next);
      if (persisted.isErr) return Err(persisted.unwrapErr());
      _sessions[peerId] = next;
      return Ok(result.unwrap().wireFormat);
    });
  }

  Future<CryptoResult<Uint8List>> decrypt({
    required String peerId,
    required Uint8List wireFormat,
    Uint8List? associatedData,
  }) {
    if (peerId.isEmpty) {
      return Future<CryptoResult<Uint8List>>.value(const Err(InvalidKey()));
    }
    return _serialize(peerId, () async {
      final restored = await _restoreLocked(peerId);
      if (restored.isErr) return Err(restored.unwrapErr());
      final ratchet = _sessions[peerId];
      if (ratchet == null) return const Err(SessionUnavailable());
      final result = await ratchet.decrypt(
        data: wireFormat,
        associatedData: associatedData,
      );
      if (result.isErr) return Err(result.unwrapErr());
      final next = result.unwrap().nextState;
      final persisted = await _persist(peerId, next);
      if (persisted.isErr) return Err(persisted.unwrapErr());
      _sessions[peerId] = next;
      return Ok(result.unwrap().wireFormat);
    });
  }

  /// Удаляет сессию пира и её сохранённое состояние.
  Future<void> removeSession(String peerId) {
    if (peerId.isEmpty) return Future<void>.value();
    return _serialize(peerId, () async {
      _sessions.remove(peerId);
      _restored.add(peerId);
      await _store?.delete(peerId);
    });
  }

  Future<CryptoResult<void>> _persist(
    String peerId,
    DoubleRatchet state,
  ) async {
    final store = _store;
    if (store == null) return const Ok(null);
    try {
      final bytes = await state.toBytes();
      final saved = await store.save(peerId, bytes);
      if (saved.isErr) return const Err(SessionPersistenceFailed());
    } catch (_) {
      return const Err(SessionPersistenceFailed());
    }
    return const Ok(null);
  }

  Future<T> _serialize<T>(String peerId, Future<T> Function() action) {
    final previous = _tails[peerId] ?? Future<void>.value();
    final completer = Completer<T>();
    _tails[peerId] = previous.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  bool _sameKey(crypto_pkg.PublicKey a, crypto_pkg.PublicKey b) {
    if (a is! crypto_pkg.SimplePublicKey || b is! crypto_pkg.SimplePublicKey) {
      return false;
    }
    if (a.type != b.type || a.bytes.length != b.bytes.length) return false;
    for (var i = 0; i < a.bytes.length; i++) {
      if (a.bytes[i] != b.bytes[i]) return false;
    }
    return true;
  }
}
