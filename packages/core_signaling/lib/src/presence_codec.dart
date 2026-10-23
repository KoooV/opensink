import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';

import 'signaling_types.dart';

/// Бинарный формат hello-body.
///
/// version(1) | platform(1) | flags(1) | uptimeSeconds(u32 BE) |
/// ipv6Len(u8) | ipv6(utf8) | neighborsCount(u16 BE) | neighbor[32]...
class PresenceCodec {
  const PresenceCodec._();

  static const int _version = 1;

  static Uint8List encode(NodeCapabilities capabilities) {
    final ipv6 = capabilities.publicIpv6 == null
        ? const <int>[]
        : utf8.encode(capabilities.publicIpv6!);
    if (ipv6.length > 255) {
      throw ArgumentError.value(
        capabilities.publicIpv6,
        'publicIpv6',
        'must be at most 255 UTF-8 bytes',
      );
    }
    if (capabilities.neighbors.length > 0xFFFF) {
      throw ArgumentError.value(
        capabilities.neighbors.length,
        'neighbors',
        'must fit into uint16',
      );
    }

    final size =
        1 +
        1 +
        1 +
        4 +
        1 +
        ipv6.length +
        2 +
        capabilities.neighbors.length * 32;
    final out = Uint8List(size);
    final data = ByteData.sublistView(out);
    var offset = 0;
    out[offset++] = _version;
    out[offset++] = capabilities.platform.wireValue;
    var flags = 0;
    if (capabilities.canRelay) {
      flags |= 0x01;
    }
    if (capabilities.canSfu) {
      flags |= 0x02;
    }
    out[offset++] = flags;
    data.setUint32(offset, capabilities.uptime.inSeconds, Endian.big);
    offset += 4;
    out[offset++] = ipv6.length;
    out.setRange(offset, offset + ipv6.length, ipv6);
    offset += ipv6.length;
    data.setUint16(offset, capabilities.neighbors.length, Endian.big);
    offset += 2;
    for (final neighbor in capabilities.neighbors) {
      if (neighbor.publicKey.length != 32) {
        throw ArgumentError.value(
          neighbor,
          'neighbors',
          'PeerId must be a 32-byte Ed25519 key',
        );
      }
      out.setRange(offset, offset + 32, neighbor.publicKey);
      offset += 32;
    }
    return out;
  }

  /// Возвращает `null` на любой некорректный вход, не бросает.
  static NodeCapabilities? decode(Uint8List bytes) {
    try {
      if (bytes.length < 10) {
        return null;
      }
      final data = ByteData.sublistView(bytes);
      var offset = 0;
      if (bytes[offset++] != _version) {
        return null;
      }
      final platform = SignalingPlatform.fromWire(bytes[offset++]);
      final flags = bytes[offset++];
      final uptimeSeconds = data.getUint32(offset, Endian.big);
      offset += 4;
      final ipv6Length = bytes[offset++];
      if (offset + ipv6Length + 2 > bytes.length) {
        return null;
      }
      final ipv6 = ipv6Length == 0
          ? null
          : utf8.decode(
              Uint8List.fromList(bytes.sublist(offset, offset + ipv6Length)),
            );
      offset += ipv6Length;
      final neighborsCount = data.getUint16(offset, Endian.big);
      offset += 2;
      if (offset + neighborsCount * 32 != bytes.length) {
        return null;
      }
      final neighbors = <PeerId>[];
      for (var i = 0; i < neighborsCount; i++) {
        neighbors.add(
          PeerId(Uint8List.fromList(bytes.sublist(offset, offset + 32))),
        );
        offset += 32;
      }
      return NodeCapabilities(
        platform: platform,
        publicIpv6: ipv6,
        uptime: Duration(seconds: uptimeSeconds),
        canRelay: flags & 0x01 != 0,
        canSfu: flags & 0x02 != 0,
        neighbors: List<PeerId>.unmodifiable(neighbors),
      );
    } catch (_) {
      return null;
    }
  }
}
