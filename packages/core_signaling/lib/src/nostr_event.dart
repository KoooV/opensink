import 'dart:convert';
import 'dart:math';

import 'package:bip340/bip340.dart' as bip340;
import 'package:core_crypto/core_crypto.dart' show bytesToHex;

import 'signaling_utils.dart';

/// Nostr-событие в формате NIP-01.
class NostrEvent {
  NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  final String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String sig;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };

  /// Каноническая строка NIP-01, из которой считается [id].
  String serializationForId() =>
      jsonEncode(<Object?>[0, pubkey, createdAt, kind, tags, content]);

  String computeId() => sha256Hex(utf8.encode(serializationForId()));

  bool hasValidId() => id == computeId();

  bool hasValidSignature() {
    if (id.length != 64 || pubkey.length != 64 || sig.length != 128) {
      return false;
    }
    try {
      return bip340.verify(pubkey, id, sig);
    } catch (_) {
      return false;
    }
  }

  static NostrEvent? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final id = value['id'];
    final pubkey = value['pubkey'];
    final createdAt = value['created_at'];
    final kind = value['kind'];
    final tags = value['tags'];
    final content = value['content'];
    final sig = value['sig'];
    if (id is! String ||
        pubkey is! String ||
        createdAt is! int ||
        kind is! int ||
        tags is! List ||
        content is! String ||
        sig is! String) {
      return null;
    }
    final parsedTags = <List<String>>[];
    for (final tag in tags) {
      if (tag is! List) {
        return null;
      }
      final parsed = <String>[];
      for (final item in tag) {
        if (item is! String) {
          return null;
        }
        parsed.add(item);
      }
      parsedTags.add(List<String>.unmodifiable(parsed));
    }
    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: List<List<String>>.unmodifiable(parsedTags),
      content: content,
      sig: sig,
    );
  }
}

/// Одноразовая secp256k1-пара сессии только для обёртки Nostr.
///
/// Реальная аутентификация — внутренний Ed25519-конверт. Ключ не сохраняется.
class NostrEphemeralSigner {
  NostrEphemeralSigner._(this.privateKeyHex, this.publicKeyHex);

  final String privateKeyHex;
  final String publicKeyHex;

  static final BigInt _curveOrder = BigInt.parse(
    'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141',
    radix: 16,
  );

  static NostrEphemeralSigner generate([Random? random]) {
    final source = random ?? Random.secure();
    for (var attempt = 0; attempt < 128; attempt++) {
      final bytes = List<int>.generate(32, (_) => source.nextInt(256));
      final scalar = BigInt.parse(bytesToHex(bytes), radix: 16);
      if (scalar == BigInt.zero || scalar >= _curveOrder) {
        continue;
      }
      return NostrEphemeralSigner._(
        bytesToHex(bytes),
        bip340.getPublicKey(bytesToHex(bytes)),
      );
    }
    throw StateError('Unable to generate a valid secp256k1 key');
  }

  /// Только для тестов/векторов.
  static NostrEphemeralSigner fromPrivateKeyHex(String privateKeyHex) {
    if (privateKeyHex.length != 64) {
      throw ArgumentError.value(
        privateKeyHex,
        'privateKeyHex',
        'must be 32 bytes hex',
      );
    }
    return NostrEphemeralSigner._(
      privateKeyHex.toLowerCase(),
      bip340.getPublicKey(privateKeyHex.toLowerCase()),
    );
  }

  NostrEvent? sign({
    required int kind,
    required List<List<String>> tags,
    required String content,
    required int createdAt,
    Random? random,
  }) {
    final event = NostrEvent(
      id: '',
      pubkey: publicKeyHex,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
      sig: '',
    );
    final id = event.computeId();
    final source = random ?? Random.secure();
    final aux = bytesToHex(List<int>.generate(32, (_) => source.nextInt(256)));
    try {
      final signature = bip340.sign(privateKeyHex, id, aux);
      return NostrEvent(
        id: id,
        pubkey: publicKeyHex,
        createdAt: createdAt,
        kind: kind,
        tags: tags,
        content: content,
        sig: signature,
      );
    } catch (_) {
      return null;
    }
  }

  bool verify(NostrEvent event) =>
      event.pubkey == publicKeyHex &&
      event.hasValidId() &&
      event.hasValidSignature();
}
