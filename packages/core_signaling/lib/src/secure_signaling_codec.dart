import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:cryptography/cryptography.dart' show SecretKey;

import 'expiring_set.dart';
import 'presence_codec.dart';
import 'rate_limiter.dart';
import 'signaling_types.dart';

/// Внешняя аутентификация отправителя.
typedef PeerAuthorizer = Future<bool> Function(PeerId peerId);

/// Конфигурация криптографической части сигнализации.
class SignalingSecurityConfig {
  const SignalingSecurityConfig({
    required this.peerId,
    required this.signer,
    required this.groupSecret,
    this.allowedPeers,
    this.isAuthorized,
  });

  final PeerId peerId;
  final Signer signer;
  final GroupSecret groupSecret;

  /// Если задан — отправитель обязан входить в набор.
  final Set<PeerId>? allowedPeers;

  /// Дополнительная проверка (например, членство в группе или инвайт).
  final PeerAuthorizer? isAuthorized;
}

sealed class OpenSignalingResult {
  const OpenSignalingResult();
}

class OpenSignalingOk extends OpenSignalingResult {
  const OpenSignalingOk(this.value);

  final OpenedSignaling value;
}

class OpenSignalingRejected extends OpenSignalingResult {
  const OpenSignalingRejected(this.reason);

  final SignalingReject reason;
}

/// Результат успешной проверки конверта.
class OpenedSignaling {
  const OpenedSignaling({
    required this.kind,
    required this.from,
    required this.to,
    required this.body,
    required this.timestamp,
  });

  final SignalingKind kind;
  final PeerId from;
  final PeerId? to;
  final Uint8List body;
  final int timestamp;
}

/// Защищённый конверт сигнализации.
///
/// Формат и обоснование — `packages/core_signaling/DESIGN.md`, §2.
class SecureSignalingCodec {
  SecureSignalingCodec({
    required this.security,
    this.limits = const SignalingLimits(),
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure(),
       _globalBucket = TokenBucket(
         capacity: limits.rateCapacity,
         refillPerSecond: limits.rateRefillPerSecond,
         clock: clock,
       ),
       _seen = ExpiringSet(
         ttl: limits.replayTtl,
         maxEntries: limits.replayMaxEntries,
         clock: clock,
       );

  final SignalingSecurityConfig security;
  final SignalingLimits limits;
  final DateTime Function() _clock;
  final Random _random;

  final TokenBucket _globalBucket;
  final ExpiringSet _seen;
  final Set<String> _pendingReplayKeys = <String>{};
  final LinkedHashMap<String, _SenderBucket> _senderBuckets =
      LinkedHashMap<String, _SenderBucket>();

  final XChaCha20Poly1305Aead _aead = XChaCha20Poly1305Aead();

  Future<SecretKey>? _payloadKey;

  static const List<int> _magic = <int>[0x4F, 0x53, 0x53, 0x47]; // OSSG
  static const int _version = 2;
  static const int _headerLength = 95;
  static const int _fixedOverhead = _headerLength + 4 + 64;
  static final Uint8List _aadPrefix = Uint8List.fromList(
    'opensink/5/signaling/v2|'.codeUnits,
  );

  Future<SecretKey> _key() =>
      _payloadKey ??= security.groupSecret.signalingPayloadKey();

  Future<Uint8List> seal({
    required String topic,
    required SignalingKind kind,
    required List<int> body,
    PeerId? to,
  }) async {
    final topicBytes = _encodeTopic(topic);
    if (body.length > limits.maxBodyBytes) {
      throw ArgumentError.value(body.length, 'body', 'exceeds maxBodyBytes');
    }
    if (to != null && to.publicKey.length != 32) {
      throw ArgumentError.value(
        to,
        'to',
        'PeerId must be a 32-byte Ed25519 key',
      );
    }

    final now = _clock();
    final nonce = _randomBytes(16);
    final header = _buildHeader(
      kind: kind,
      from: security.peerId,
      to: to,
      timestamp: now.millisecondsSinceEpoch,
      nonce: nonce,
    );
    final plaintext = _encodePlaintext(body);
    final key = await _key();
    final encrypted = await _aead.encrypt(
      key: key,
      plaintext: plaintext,
      aad: _aad(topicBytes, header),
    );
    final ciphertext = encrypted.unwrap();

    final signedLength = _headerLength + 4 + ciphertext.length;
    final signed = Uint8List(signedLength);
    signed.setRange(0, _headerLength, header);
    ByteData.sublistView(signed)
        .setUint32(_headerLength, ciphertext.length, Endian.big);
    signed.setRange(_headerLength + 4, signedLength, ciphertext);

    final signatureHex = await security.signer.sign(signed);
    final signature = Uint8List.fromList(hexToBytes(signatureHex));
    if (signature.length != 64) {
      throw StateError('Ed25519 signer returned a non-64-byte signature');
    }

    final packet = Uint8List(signedLength + 64);
    packet.setRange(0, signedLength, signed);
    packet.setRange(signedLength, packet.length, signature);
    return packet;
  }

  Future<OpenSignalingResult> open(
    Uint8List packet, {
    required String topic,
  }) async {
    final topicBytes = _encodeTopic(topic);
    if (packet.length > limits.maxPacketBytes) {
      return const OpenSignalingRejected(SignalingReject.tooLarge);
    }
    if (packet.length < _fixedOverhead + 16) {
      return const OpenSignalingRejected(SignalingReject.malformed);
    }
    if (!_hasMagic(packet)) {
      return const OpenSignalingRejected(SignalingReject.malformed);
    }
    if (packet[4] != _version) {
      return const OpenSignalingRejected(SignalingReject.badVersion);
    }

    final kind = SignalingKind.fromWire(packet[5]);
    if (kind == null) {
      return const OpenSignalingRejected(SignalingReject.malformed);
    }
    final hasRecipient = packet[6] & 0x01 != 0;
    if (packet[6] & 0xFE != 0) {
      return const OpenSignalingRejected(SignalingReject.malformed);
    }

    final senderBytes = Uint8List.fromList(packet.sublist(7, 39));
    final recipientBytes = Uint8List.fromList(packet.sublist(39, 71));
    final sender = PeerId(senderBytes);
    final recipient = hasRecipient ? PeerId(recipientBytes) : null;
    if (hasRecipient && _isZero(recipientBytes)) {
      return const OpenSignalingRejected(SignalingReject.malformed);
    }
    if (!hasRecipient && !_isZero(recipientBytes)) {
      return const OpenSignalingRejected(SignalingReject.malformed);
    }

    final data = ByteData.sublistView(packet);
    final timestamp = _readInt64BE(data, 71);
    final nonce = packet.sublist(79, 95);
    final cipherLength = data.getUint32(_headerLength, Endian.big);
    final expectedLength = _headerLength + 4 + cipherLength + 64;
    if (cipherLength < 16 ||
        cipherLength > limits.maxPacketBytes ||
        expectedLength != packet.length) {
      return const OpenSignalingRejected(SignalingReject.malformed);
    }

    if (!_globalBucket.tryConsume()) {
      return const OpenSignalingRejected(SignalingReject.rateLimited);
    }
    final senderKey = bytesToHex(senderBytes);
    if (!_senderBucket(senderKey).tryConsume()) {
      return const OpenSignalingRejected(SignalingReject.rateLimited);
    }
    _pruneSenderBuckets();

    if (sender == security.peerId) {
      return const OpenSignalingRejected(SignalingReject.selfEcho);
    }

    final replayKey = '$senderKey:${bytesToHex(nonce)}';
    if (_seen.contains(replayKey) || !_pendingReplayKeys.add(replayKey)) {
      return const OpenSignalingRejected(SignalingReject.replayed);
    }

    try {
      final allowed = security.allowedPeers;
      if (allowed != null && !allowed.contains(sender)) {
        return const OpenSignalingRejected(SignalingReject.unauthorized);
      }
      final authorizer = security.isAuthorized;
      if (authorizer != null && !await authorizer(sender)) {
        return const OpenSignalingRejected(SignalingReject.unauthorized);
      }

      final signedLength = _headerLength + 4 + cipherLength;
      final signed = Uint8List.sublistView(packet, 0, signedLength);
      final signature = Uint8List.fromList(
        packet.sublist(signedLength, packet.length),
      );
      final verified = await security.signer.verify(
        signed,
        bytesToHex(signature),
        sender,
      );
      if (!verified) {
        return const OpenSignalingRejected(SignalingReject.badSignature);
      }

      final now = _clock().millisecondsSinceEpoch;
      if ((now - timestamp).abs() > limits.maxClockSkew.inMilliseconds) {
        return const OpenSignalingRejected(SignalingReject.expired);
      }

      if (recipient != null && recipient != security.peerId) {
        return const OpenSignalingRejected(SignalingReject.notForMe);
      }

      final header = Uint8List.sublistView(packet, 0, _headerLength);
      final ciphertext = Uint8List.sublistView(
        packet,
        _headerLength + 4,
        signedLength,
      );
      final decrypted = await _aead.decrypt(
        key: await _key(),
        data: ciphertext,
        aad: _aad(topicBytes, header),
      );
      if (decrypted.isErr) {
        return const OpenSignalingRejected(SignalingReject.undecryptable);
      }
      final body = _decodePlaintext(decrypted.unwrap());
      if (body == null) {
        return const OpenSignalingRejected(SignalingReject.malformed);
      }
      _seen.add(replayKey);
      return OpenSignalingOk(
        OpenedSignaling(
          kind: kind,
          from: sender,
          to: recipient,
          body: body,
          timestamp: timestamp,
        ),
      );
    } finally {
      _pendingReplayKeys.remove(replayKey);
    }
  }

  /// Кодирует hello-body.
  static Uint8List encodeHello(NodeCapabilities capabilities) =>
      PresenceCodec.encode(capabilities);

  /// Декодирует hello-body.
  static NodeCapabilities? decodeHello(List<int> body) =>
      PresenceCodec.decode(Uint8List.fromList(body));

  Uint8List _buildHeader({
    required SignalingKind kind,
    required PeerId from,
    required PeerId? to,
    required int timestamp,
    required Uint8List nonce,
  }) {
    final header = Uint8List(_headerLength);
    header.setRange(0, 4, _magic);
    header[4] = _version;
    header[5] = kind.wireValue;
    header[6] = to == null ? 0 : 0x01;
    header.setRange(7, 39, from.publicKey);
    if (to != null) {
      header.setRange(39, 71, to.publicKey);
    }
    final data = ByteData.sublistView(header);
    _writeInt64BE(data, 71, timestamp);
    header.setRange(79, 95, nonce);
    return header;
  }

  Uint8List _encodePlaintext(List<int> body) {
    final out = Uint8List(1 + 4 + body.length);
    out[0] = _version;
    ByteData.sublistView(out).setUint32(1, body.length, Endian.big);
    out.setRange(5, out.length, body);
    return out;
  }

  Uint8List? _decodePlaintext(Uint8List plaintext) {
    if (plaintext.length < 5 || plaintext[0] != _version) {
      return null;
    }
    final length = ByteData.sublistView(plaintext).getUint32(1, Endian.big);
    if (length > limits.maxBodyBytes || length != plaintext.length - 5) {
      return null;
    }
    return Uint8List.fromList(plaintext.sublist(5));
  }

  /// dart2js не поддерживает `ByteData.setInt64/getInt64`. Unix-ms всегда
  /// неотрицателен и помещается в JS-safe integer, поэтому пишем две
  /// 32-битные половины без BigInt.
  static void _writeInt64BE(ByteData data, int offset, int value) {
    final high = (value ~/ 0x100000000) & 0xFFFFFFFF;
    final low = value % 0x100000000;
    data.setUint32(offset, high, Endian.big);
    data.setUint32(offset + 4, low, Endian.big);
  }

  static int _readInt64BE(ByteData data, int offset) {
    final high = data.getUint32(offset, Endian.big);
    final low = data.getUint32(offset + 4, Endian.big);
    return high * 0x100000000 + low;
  }

  /// AAD = prefix | topic_len(u32 BE) | topic(utf8) | header.
  /// Длина топика исключает неоднозначность склейки.
  Uint8List _aad(Uint8List topicBytes, Uint8List header) {
    final aad = Uint8List(
      _aadPrefix.length + 4 + topicBytes.length + header.length,
    );
    var offset = 0;
    aad.setRange(offset, offset + _aadPrefix.length, _aadPrefix);
    offset += _aadPrefix.length;
    ByteData.sublistView(aad).setUint32(offset, topicBytes.length, Endian.big);
    offset += 4;
    aad.setRange(offset, offset + topicBytes.length, topicBytes);
    offset += topicBytes.length;
    aad.setRange(offset, aad.length, header);
    return aad;
  }

  Uint8List _encodeTopic(String topic) {
    final bytes = Uint8List.fromList(utf8.encode(topic));
    if (bytes.length > 4096) {
      throw ArgumentError.value(
        topic,
        'topic',
        'must be at most 4096 UTF-8 bytes',
      );
    }
    return bytes;
  }

  TokenBucket _senderBucket(String senderHex) {
    final existing = _senderBuckets[senderHex];
    if (existing != null) {
      existing.lastUsed = _clock();
      return existing.bucket;
    }
    final bucket = _SenderBucket(
      TokenBucket(
        capacity: limits.perSenderRateCapacity,
        refillPerSecond: limits.perSenderRefillPerSecond,
        clock: _clock,
      ),
      _clock(),
    );
    _senderBuckets[senderHex] = bucket;
    return bucket.bucket;
  }

  void _pruneSenderBuckets() {
    if (_senderBuckets.length <= 512) {
      return;
    }
    final threshold = _clock().subtract(const Duration(minutes: 5));
    _senderBuckets.removeWhere(
      (_, value) => value.lastUsed.isBefore(threshold),
    );
    while (_senderBuckets.length > 1024) {
      _senderBuckets.remove(_senderBuckets.keys.first);
    }
  }

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  bool _hasMagic(Uint8List packet) {
    for (var i = 0; i < _magic.length; i++) {
      if (packet[i] != _magic[i]) {
        return false;
      }
    }
    return true;
  }

  bool _isZero(Uint8List bytes) {
    for (final byte in bytes) {
      if (byte != 0) {
        return false;
      }
    }
    return true;
  }
}

class _SenderBucket {
  _SenderBucket(this.bucket, this.lastUsed);

  final TokenBucket bucket;
  DateTime lastUsed;
}
