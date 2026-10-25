import 'dart:async';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:cryptography/cryptography.dart' as crypto_pkg;

import 'e2e_datagram_transport.dart';

/// Личный E2E-канал sender-key пакетов поверх [E2eDatagramTransport].
///
/// Инициатор сессии детерминирован (меньший PeerId), поэтому обе стороны
/// сходятся к одной X3DH-сессии. Транспорт выбирается по `groupId` пакета.
/// Все операции с сессией пира сериализуются: параллельные handshake/data
/// не перезаписывают ratchet. Входящий пакет публикуется только после
/// расшифровки и сверки отправителя/получателя/группы.
class E2eSenderKeyChannel implements SenderKeyChannel {
  E2eSenderKeyChannel({
    required this.localPeerId,
    required this.sessions,
    this.packageCodec = const SenderKeyPackageCodec(),
    this.maxEnvelopeBytes = 128 * 1024,
  });

  final PeerId localPeerId;
  final E2eSessionManager sessions;
  final SenderKeyPackageCodec packageCodec;
  final int maxEnvelopeBytes;

  final Map<PeerId, _PeerBundle> _bundles = <PeerId, _PeerBundle>{};
  final Map<GroupId, E2eDatagramTransport> _transports =
      <GroupId, E2eDatagramTransport>{};
  final Map<GroupId, StreamSubscription<E2eDatagram>> _subscriptions =
      <GroupId, StreamSubscription<E2eDatagram>>{};
  final Map<PeerId, Uint8List> _pendingHandshakes = <PeerId, Uint8List>{};
  final Map<PeerId, Uint8List> _sentHandshakes = <PeerId, Uint8List>{};
  final Map<PeerId, Future<void>> _tails = <PeerId, Future<void>>{};
  final StreamController<SenderKeyPackage> _received =
      StreamController<SenderKeyPackage>.broadcast();
  final StreamController<PeerId> _established =
      StreamController<PeerId>.broadcast();
  bool _closed = false;

  /// Расшифрованные и структурно валидные sender-key пакеты.
  Stream<SenderKeyPackage> get received => _received.stream;

  /// Пиры, с которыми установлена/принята E2E-сессия.
  Stream<PeerId> get established => _established.stream;

  UserId get _localUser => UserId(_hex(localPeerId.publicKey));

  bool hasSession(PeerId peer) => sessions.hasSession(_hex(peer.publicKey));

  Future<bool> _ensureSessionState(PeerId peer) async {
    final hadSession = hasSession(peer);
    final restored = await sessions.restoreSession(_hex(peer.publicKey));
    if (restored.isErr) return false;
    if (!hadSession && hasSession(peer)) _notifyEstablished(peer);
    return true;
  }

  void _notifyEstablished(PeerId peer) {
    if (!_established.isClosed) _established.add(peer);
  }

  /// Привязывает транспорт группы. `null` отвязывает только эту группу.
  Future<void> bindTransport(
    GroupId groupId,
    E2eDatagramTransport? transport,
  ) async {
    final previous = _subscriptions.remove(groupId);
    await previous?.cancel();
    _transports.remove(groupId);
    if (_closed || transport == null) return;
    _transports[groupId] = transport;
    await transport.start();
    _subscriptions[groupId] = transport.incoming.listen(
      (datagram) => unawaited(
        _serialize(datagram.from, () => _onDatagram(datagram, groupId)),
      ),
      onError: (Object _) {},
    );
    for (final entry in _bundles.entries) {
      if (entry.value.groupId != groupId) continue;
      unawaited(
        _serialize(
          entry.key,
          () => _initiateLocked(entry.key, entry.value, transport),
        ),
      );
    }
  }

  /// Отвязывает только [transport], не затрагивая более новый транспорт
  /// той же группы (защита от гонки dispose/rebind).
  Future<void> unbindTransport(
    GroupId groupId,
    E2eDatagramTransport transport,
  ) async {
    if (!identical(_transports[groupId], transport)) return;
    await bindTransport(groupId, null);
  }

  /// Запоминает публичный бандл пира из presence группы [groupId] и, если
  /// роль инициатора наша, устанавливает сессию.
  Future<Result<void, SenderKeyDeliveryError>> registerBundle(
    GroupId groupId,
    PeerId peer,
    X3DHPublicBundle bundle,
  ) async {
    if (_closed) {
      return const Err(SenderKeyDeliveryRejected('E2E channel is closed'));
    }
    if (peer == localPeerId) {
      return const Err(SenderKeyDeliveryRejected('self bundle'));
    }
    if (!_identityMatches(peer, bundle.ed25519PublicKey)) {
      return const Err(SenderKeyDeliveryRejected('bundle identity mismatch'));
    }
    if (!await sessions.verifyRemoteBundle(bundle)) {
      return const Err(SenderKeyDeliveryRejected('invalid SPK binding'));
    }
    if (!await _ensureSessionState(peer)) {
      return const Err(SenderKeyDeliveryRejected('E2E session restore failed'));
    }
    final entry = _PeerBundle(groupId: groupId, bundle: bundle);
    _bundles[peer] = entry;
    final pending = _pendingHandshakes.remove(peer);
    if (pending != null) {
      await _serialize(peer, () => _acceptHandshakeLocked(peer, pending));
    }
    final transport = _transports[groupId];
    if (transport != null) {
      await _serialize(peer, () async {
        if (!hasSession(peer)) {
          return _initiateLocked(peer, entry, transport);
        }
        return _resendHandshakeLocked(peer, transport);
      });
    }
    return const Ok(null);
  }

  @override
  Future<Result<void, SenderKeyDeliveryError>> send(
    UserId recipient,
    Uint8List payload,
  ) async {
    if (_closed) {
      return const Err(SenderKeyDeliveryRejected('E2E channel is closed'));
    }
    final peer = _peerFor(recipient);
    if (peer == null || peer == localPeerId) {
      return Err(SenderKeyRecipientUnavailable(recipient));
    }
    final package = packageCodec.decode(payload);
    if (package.isErr) {
      return const Err(SenderKeyDeliveryRejected('invalid sender key package'));
    }
    final groupId = package.unwrap().groupId;
    final transport = _transports[groupId];
    if (transport == null) {
      return Err(SenderKeyRecipientUnavailable(recipient));
    }
    if (!await _ensureSessionState(peer)) {
      return const Err(SenderKeyDeliveryRejected('E2E session restore failed'));
    }
    return _serialize(peer, () async {
      if (!hasSession(peer)) {
        final entry = _bundles[peer];
        if (entry == null || !_shouldInitiate(peer)) {
          return Err(SenderKeyRecipientUnavailable(recipient));
        }
        final established = await _initiate(peer, entry, transport);
        if (!established) {
          return Err(SenderKeyRecipientUnavailable(recipient));
        }
      }
      final encrypted = await sessions.encrypt(
        peerId: _hex(peer.publicKey),
        plaintext: payload,
      );
      if (encrypted.isErr) {
        return const Err(SenderKeyDeliveryRejected('E2E encryption failed'));
      }
      try {
        await transport.send(peer, _encodeData(encrypted.unwrap()));
      } catch (_) {
        return const Err(SenderKeyDeliveryRejected('E2E transport failed'));
      }
      return const Ok(null);
    });
  }

  Future<T> _serialize<T>(PeerId peer, Future<T> Function() action) {
    final previous = _tails[peer] ?? Future<void>.value();
    final completer = Completer<T>();
    _tails[peer] = previous.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<Result<void, SenderKeyDeliveryError>> _initiateLocked(
    PeerId peer,
    _PeerBundle entry,
    E2eDatagramTransport transport,
  ) async {
    final established = await _initiate(peer, entry, transport);
    if (established || hasSession(peer)) return const Ok(null);
    return const Err(SenderKeyDeliveryRejected('handshake unavailable'));
  }

  Future<bool> _initiate(
    PeerId peer,
    _PeerBundle entry,
    E2eDatagramTransport transport,
  ) async {
    if (_closed || !_shouldInitiate(peer)) return false;
    if (!await _ensureSessionState(peer)) return false;
    if (hasSession(peer)) return false;
    final peerId = _hex(peer.publicKey);
    final expected = crypto_pkg.SimplePublicKey(
      Uint8List.fromList(peer.publicKey),
      type: crypto_pkg.KeyPairType.ed25519,
    );
    final handshake = await sessions.initiate(
      peerId: peerId,
      remoteBundle: entry.bundle,
      expectedEd25519PublicKey: expected,
    );
    if (handshake.isErr) return false;
    final handshakeBytes = handshake.unwrap().toBytes();
    try {
      await transport.send(peer, _encodeHandshake(handshakeBytes));
    } catch (_) {
      await sessions.removeSession(peerId);
      return false;
    }
    _sentHandshakes[peer] = handshakeBytes;
    _notifyEstablished(peer);
    return true;
  }

  Future<Result<void, SenderKeyDeliveryError>> _resendHandshakeLocked(
    PeerId peer,
    E2eDatagramTransport transport,
  ) async {
    final handshake = _sentHandshakes[peer];
    if (handshake == null || !_shouldInitiate(peer)) return const Ok(null);
    try {
      await transport.send(peer, _encodeHandshake(handshake));
      return const Ok(null);
    } catch (_) {
      return const Err(SenderKeyDeliveryRejected('E2E transport failed'));
    }
  }

  Future<Result<void, SenderKeyDeliveryError>> _onDatagram(
    E2eDatagram datagram,
    GroupId groupId,
  ) async {
    if (_closed) return const Ok(null);
    final decoded = _decode(datagram.bytes);
    if (decoded == null) {
      return const Err(SenderKeyDeliveryRejected('invalid envelope'));
    }
    final peerId = _hex(datagram.from.publicKey);
    if (decoded.handshake) {
      if (_shouldInitiate(datagram.from)) {
        return const Err(SenderKeyDeliveryRejected('unexpected handshake'));
      }
      if (_bundles[datagram.from] == null) {
        _pendingHandshakes[datagram.from] = decoded.body;
        return const Ok(null);
      }
      return _acceptHandshakeLocked(datagram.from, decoded.body);
    }
    if (!await _ensureSessionState(datagram.from)) {
      return const Err(SenderKeyDeliveryRejected('E2E session restore failed'));
    }
    if (!hasSession(datagram.from)) {
      return const Err(SenderKeyDeliveryRejected('session unavailable'));
    }
    final decrypted = await sessions.decrypt(
      peerId: peerId,
      wireFormat: decoded.body,
    );
    if (decrypted.isErr) {
      return const Err(SenderKeyDeliveryRejected('E2E decryption failed'));
    }
    final package = packageCodec.decode(decrypted.unwrap());
    if (package.isErr) {
      return const Err(SenderKeyDeliveryRejected('invalid sender key package'));
    }
    final value = package.unwrap();
    if (value.sender != UserId(peerId) ||
        value.recipient != _localUser ||
        value.groupId != groupId) {
      return const Err(SenderKeyDeliveryRejected('sender key mismatch'));
    }
    _sentHandshakes.remove(datagram.from);
    if (!_received.isClosed) {
      _received.add(value);
    }
    return const Ok(null);
  }

  Future<Result<void, SenderKeyDeliveryError>> _acceptHandshakeLocked(
    PeerId peer,
    Uint8List handshake,
  ) async {
    if (!await _ensureSessionState(peer)) {
      return const Err(SenderKeyDeliveryRejected('E2E session restore failed'));
    }
    if (hasSession(peer)) return const Ok(null);
    final accepted = await sessions.accept(
      peerId: _hex(peer.publicKey),
      handshake: handshake,
    );
    if (accepted.isErr) {
      return const Err(SenderKeyDeliveryRejected('handshake rejected'));
    }
    _notifyEstablished(peer);
    return const Ok(null);
  }

  bool _shouldInitiate(PeerId peer) {
    final local = localPeerId.publicKey;
    final remote = peer.publicKey;
    final length = local.length < remote.length ? local.length : remote.length;
    for (var index = 0; index < length; index++) {
      if (local[index] == remote[index]) continue;
      return local[index] < remote[index];
    }
    return local.length < remote.length;
  }

  bool _identityMatches(PeerId peer, crypto_pkg.PublicKey key) {
    if (key is! crypto_pkg.SimplePublicKey) return false;
    final bytes = key.bytes;
    if (bytes.length != peer.publicKey.length) return false;
    for (var index = 0; index < bytes.length; index++) {
      if (bytes[index] != peer.publicKey[index]) return false;
    }
    return true;
  }

  PeerId? _peerFor(UserId user) {
    final bytes = _decodeHex(user.value);
    if (bytes == null || bytes.length != 32) return null;
    return PeerId(bytes);
  }

  Uint8List _encodeHandshake(Uint8List handshake) {
    return Uint8List.fromList(<int>[1, 1, ...handshake]);
  }

  Uint8List _encodeData(Uint8List ciphertext) {
    return Uint8List.fromList(<int>[1, 2, ...ciphertext]);
  }

  _DecodedEnvelope? _decode(Uint8List bytes) {
    if (bytes.length < 3 || bytes.length > maxEnvelopeBytes) return null;
    if (bytes[0] != 1) return null;
    final body = Uint8List.fromList(bytes.sublist(2));
    switch (bytes[1]) {
      case 1:
        return _DecodedEnvelope(handshake: true, body: body);
      case 2:
        return _DecodedEnvelope(handshake: false, body: body);
      default:
        return null;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions.values) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _transports.clear();
    _bundles.clear();
    _pendingHandshakes.clear();
    _sentHandshakes.clear();
    _tails.clear();
    if (!_received.isClosed) {
      await _received.close();
    }
    if (!_established.isClosed) {
      await _established.close();
    }
  }
}

class _PeerBundle {
  const _PeerBundle({required this.groupId, required this.bundle});

  final GroupId groupId;
  final X3DHPublicBundle bundle;
}

class _DecodedEnvelope {
  const _DecodedEnvelope({required this.handshake, required this.body});

  final bool handshake;
  final Uint8List body;
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List? _decodeHex(String value) {
  if (value.length.isOdd) return null;
  final result = Uint8List(value.length ~/ 2);
  for (var index = 0; index < result.length; index++) {
    final byte = int.tryParse(
      value.substring(index * 2, index * 2 + 2),
      radix: 16,
    );
    if (byte == null) return null;
    result[index] = byte;
  }
  return result;
}
