import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide RelayFrame;
import 'package:core_protocol/core_protocol.dart' show RelayFrame;

/// Подпись origin над неизменяемыми полями relay-кадра.
///
/// `ttl` и `hopCount` меняются на каждом хопе, поэтому подписывается их сумма
/// `originTtl = ttl + hopCount`. Это не даёт увеличить исходный hop-budget,
/// хотя вредоносный релей всё ещё может перераспределить пару значений.
class RelayFrameAuth {
  const RelayFrameAuth._();

  static const String domain = 'opensink/relay/frame/v2|';

  static Uint8List signingBytes(RelayFrame frame) {
    if (frame.src.length != 32 || frame.dst.length != 32) {
      throw const FormatException('relay frame keys must be 32 bytes');
    }
    if (frame.nonce.length != 16) {
      throw const FormatException('relay frame nonce must be 16 bytes');
    }
    final originTtl = frame.ttl + frame.hopCount;
    if (originTtl < 0 || originTtl > 0xFFFFFFFF) {
      throw const FormatException('invalid relay originTtl');
    }
    if (frame.payload.length > 0xFFFFFFFF) {
      throw const FormatException('relay payload too large');
    }
    final prefix = domain.codeUnits;
    final out = Uint8List(
      prefix.length + 32 + 32 + 16 + 4 + 4 + frame.payload.length,
    );
    var offset = 0;
    out.setRange(offset, offset + prefix.length, prefix);
    offset += prefix.length;
    out.setRange(offset, offset + 32, frame.src);
    offset += 32;
    out.setRange(offset, offset + 32, frame.dst);
    offset += 32;
    out.setRange(offset, offset + 16, frame.nonce);
    offset += 16;
    final data = ByteData.sublistView(out);
    data.setUint32(offset, originTtl, Endian.big);
    offset += 4;
    data.setUint32(offset, frame.payload.length, Endian.big);
    offset += 4;
    out.setRange(offset, out.length, frame.payload);
    return out;
  }

  static Future<Uint8List> sign(RelayFrame frame, Signer signer) async {
    final signatureHex = await signer.sign(signingBytes(frame));
    final signature = _hexToBytes(signatureHex);
    if (signature.length != 64) {
      throw StateError('Ed25519 signer returned a non-64-byte signature');
    }
    return signature;
  }

  static Future<bool> verify(
    RelayFrame frame,
    PeerId src,
    Signer signer,
  ) async {
    if (frame.signature.length != 64) {
      return false;
    }
    try {
      return await signer.verify(
        signingBytes(frame),
        _bytesToHex(frame.signature),
        src,
      );
    } catch (_) {
      return false;
    }
  }

  static Uint8List _hexToBytes(String value) {
    if (value.length.isOdd) {
      throw const FormatException('odd hex length');
    }
    final out = Uint8List(value.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _bytesToHex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
