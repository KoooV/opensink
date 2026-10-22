import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide GroupEvent, RelayFrame;

import 'envelope.dart';
import 'limits.dart';
import 'message_type.dart';
import 'messages.dart';
import 'protocol_error.dart';
import 'wire.dart';

/// Утилиты кодирования/декодирования hex (для подписи и peer-id).
class _Hex {
  static const _chars = '0123456789abcdef';

  static String encode(Uint8List bytes) {
    final result = StringBuffer();
    for (final b in bytes) {
      result.write(_chars[(b >> 4) & 0xF]);
      result.write(_chars[b & 0xF]);
    }
    return result.toString();
  }

  static Uint8List decode(String hex) {
    if (hex.isEmpty) return Uint8List(0);
    if (hex.length % 2 != 0) {
      throw const FormatException('hex string has odd length');
    }
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      final high = _charValue(hex[i * 2]);
      final low = _charValue(hex[i * 2 + 1]);
      bytes[i] = (high << 4) | low;
    }
    return bytes;
  }

  static int _charValue(String c) {
    final code = c.codeUnitAt(0);
    if (code >= 0x30 && code <= 0x39) return code - 0x30; // 0-9
    if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10; // A-F
    if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10; // a-f
    throw FormatException('invalid hex character: $c');
  }
}

/// Фасад протокола OpenSink: кодирование, декодирование, подпись,
/// верификация, чанкование и сборка больших вложений.
///
/// Все методы кодирования/декодирования синхронны и возвращают
/// [Result] вместо выбрасывания исключений. Криптографические операции
/// (подпись/верификация) асинхронны, поскольку [Signer] асинхронен.
class ProtocolCodec {
  ProtocolCodec();

  /// Сериализует [envelope] в байты protobuf с валидацией лимитов.
  Result<Uint8List, ProtocolError> encode(Envelope envelope) {
    if (envelope.version < ProtocolLimits.minSupportedVersion) {
      return Err(UnknownVersion(envelope.version));
    }
    if (envelope.sender.length > ProtocolLimits.maxPeerIdBytes) {
      return Err(SizeLimitExceeded(
          envelope.sender.length, ProtocolLimits.maxPeerIdBytes));
    }
    if (envelope.signature.length > ProtocolLimits.maxSignatureBytes) {
      return Err(SizeLimitExceeded(
          envelope.signature.length, ProtocolLimits.maxSignatureBytes));
    }
    // Предварительная проверка размера payload до аллокации всего буфера.
    if (envelope.payload.length > ProtocolLimits.maxPayloadSize) {
      return Err(SizeLimitExceeded(
          envelope.payload.length, ProtocolLimits.maxPayloadSize));
    }
    // Проверяем, что закодированный размер не превышает лимит фрейма.
    final encoded = envelope.toBytes();
    if (encoded.length > ProtocolLimits.maxFrameSize) {
      return Err(SizeLimitExceeded(
          encoded.length, ProtocolLimits.maxFrameSize));
    }
    return Ok(encoded);
  }

  /// Десериализует байты в [Envelope] с валидацией структуры и лимитов.
  ///
  /// Некорректный вход никогда не бросает исключение — возвращается [Err].
  /// Аллокаций ограничено [ProtocolLimits.maxFrameSize].
  Result<Envelope, ProtocolError> decode(Uint8List bytes) {
    if (bytes.length > ProtocolLimits.maxFrameSize) {
      return Err(SizeLimitExceeded(
          bytes.length, ProtocolLimits.maxFrameSize));
    }
    if (bytes.isEmpty) {
      return const Err(DecodeError('empty input'));
    }
    try {
      final reader = ProtoReader(bytes);
      final envelope = Envelope.fromReader(reader);
      // Проверяем версию.
      if (envelope.version < ProtocolLimits.minSupportedVersion) {
        return Err(UnknownVersion(envelope.version));
      }
      // Проверяем размер payload.
      if (envelope.payload.length > ProtocolLimits.maxPayloadSize) {
        return Err(SizeLimitExceeded(
            envelope.payload.length, ProtocolLimits.maxPayloadSize));
      }
      return Ok(envelope);
    } on ProtocolError catch (e) {
      return Err(e);
    } catch (e, s) {
      // Любая необработанная ошибка парсинга — это DecodeError, а не исключение.
      return Err(DecodeError('unexpected decode failure: $e', s.toString()));
    }
  }

  /// Подписывает [envelope] закрытым ключом и возвращает новый энвелоп с
  /// подписью. Подпись считается над [Envelope.signatureData].
  Future<Result<Envelope, ProtocolError>> sign(
    Envelope envelope,
    Signer signer, {
    PeerId? senderPeerId,
  }) async {
    if (envelope.sender.isEmpty) {
      return const Err(ValidationError('sender is required for signing'));
    }
    try {
      final signatureHex = await signer.sign(envelope.signatureData());
      final signatureBytes = _Hex.decode(signatureHex);
      if (signatureBytes.length > ProtocolLimits.maxSignatureBytes) {
        return Err(SizeLimitExceeded(
            signatureBytes.length, ProtocolLimits.maxSignatureBytes));
      }
      return Ok(envelope.copyWith(signature: signatureBytes));
    } on ProtocolError catch (e) {
      return Err(e);
    } catch (e) {
      return Err(ValidationError('signing failed: $e'));
    }
  }

  /// Верифицирует подпись [envelope] открытым ключом [senderPeerId].
  ///
  /// Возвращает [Ok(true)] если подпись верна, [Ok(false)] если неверна,
  /// [Err] при ошибке проверки.
  Future<Result<bool, ProtocolError>> verify(
    Envelope envelope,
    Signer signer,
    PeerId senderPeerId, {
    bool allowEmptySignature = false,
  }) async {
    if (envelope.signature.isEmpty) {
      if (allowEmptySignature) {
        return const Ok(false);
      }
      return const Err(InvalidSignature());
    }
    try {
      final signatureHex = _Hex.encode(envelope.signature);
      final valid = await signer.verify(
        envelope.signatureData(),
        signatureHex,
        senderPeerId,
      );
      return Ok(valid);
    } on ProtocolError catch (e) {
      return Err(e);
    } catch (e) {
      return Err(ValidationError('verification failed: $e'));
    }
  }

  /// Чанкует [data] на фрагменты [FileChunk] с идентификатором [fileId].
  ///
  /// Каждый чанк не превышает [ProtocolLimits.maxChunkSize]. Возвращает
  /// чанки в порядке возрастания их индексов.
  ///
  /// Если передан [sha256], вычисляется хэш каждого чанка; иначе
  /// поле chunkHash остаётся пустым (заглушка).
  Future<Result<List<FileChunk>, ProtocolError>> chunkPayload(
    String fileId,
    Uint8List data, {
    Uint8List? fileSha256,
    Future<Uint8List> Function(Uint8List)? sha256,
  }) async {
    if (fileId.isEmpty) {
      return const Err(ValidationError('fileId is required'));
    }
    if (data.isEmpty) {
      return const Ok([]);
    }
    final totalSize = data.length;
    if (totalSize > ProtocolLimits.maxPayloadSize) {
      return Err(SizeLimitExceeded(
          totalSize, ProtocolLimits.maxPayloadSize));
    }
    final totalChunks = (totalSize / ProtocolLimits.maxChunkSize).ceil();
    if (totalChunks > ProtocolLimits.maxRepeatedItems) {
      return Err(AllocationLimitExceeded(
          totalChunks, ProtocolLimits.maxRepeatedItems));
    }
    final chunks = <FileChunk>[];
    var offset = 0;
    var chunkIndex = 0;
    while (offset < totalSize) {
      final end = (offset + ProtocolLimits.maxChunkSize).clamp(0, totalSize);
      final chunkData = data.sublist(offset, end);
      final chunkHash = sha256 != null ? await sha256(chunkData) : Uint8List(0);
      chunks.add(FileChunk(
        fileId: fileId,
        chunkIndex: chunkIndex,
        totalChunks: totalChunks,
        data: chunkData,
        totalSize: totalSize,
        sha256: fileSha256 ?? Uint8List(0),
        chunkHash: chunkHash,
      ));
      offset = end;
      chunkIndex++;
    }
    return Ok(chunks);
  }

  /// Собирает чанки [chunks] одного файла обратно в байты.
  ///
  /// Чанки должны принадлежать одному файлу, покрывать диапазон индексов
  /// от 0 до totalChunks без пропусков и дублей.
  Result<Uint8List, ProtocolError> reassemblePayload(List<FileChunk> chunks) {
    if (chunks.isEmpty) {
      return const Err(ChunkingError('no chunks to reassemble'));
    }
    final fileId = chunks.first.fileId;
    if (chunks.any((c) => c.fileId != fileId)) {
      return const Err(ChunkingError('chunks belong to different files'));
    }
    final totalChunks = chunks.first.totalChunks;
    if (chunks.any((c) => c.totalChunks != totalChunks)) {
      return const Err(ChunkingError('inconsistent totalChunks'));
    }
    final totalSize = chunks.first.totalSize;
    if (chunks.any((c) => c.totalSize != totalSize)) {
      return const Err(ChunkingError('inconsistent totalSize'));
    }
    final sorted = List<FileChunk>.from(chunks)
      ..sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i].chunkIndex != i) {
        return const Err(ChunkingError('missing or duplicate chunk index'));
      }
    }
    // Проверяем общий размер против лимита payload.
    var reassembledLength = 0;
    for (final chunk in sorted) {
      reassembledLength += chunk.data.length;
      if (reassembledLength > ProtocolLimits.maxPayloadSize) {
        return Err(SizeLimitExceeded(
            reassembledLength, ProtocolLimits.maxPayloadSize));
      }
    }
    final result = Uint8List(reassembledLength);
    var writeOffset = 0;
    for (final chunk in sorted) {
      result.setRange(writeOffset, writeOffset + chunk.data.length, chunk.data);
      writeOffset += chunk.data.length;
    }
    return Ok(result);
  }

  /// Упаковывает произвольный payload в [Envelope] типа [type].
  Envelope makeEnvelope({
    required MessageType type,
    required Uint8List sender,
    required int hlc,
    required Uint8List payload,
    required Uint8List signature,
  }) {
    return Envelope(
      version: ProtocolLimits.currentVersion,
      type: type,
      sender: sender,
      hlc: hlc,
      payload: payload,
      signature: signature,
    );
  }

  /// Извлекает внутреннее сообщение конверта по его типу.
  ///
  /// Никогда не бросает исключение — битый payload возвращается как [Err].
  ///
  /// Конверты с версией выше [ProtocolLimits.maxSupportedVersion]
  /// отклоняются с [UnsupportedFutureVersion]: такие конверты можно
  /// пересылать релеем ([Envelope.fromBytes] / [Envelope.toBytes]),
  /// но не интерпретировать локально (fail-closed).
  Result<Object, ProtocolError> decodePayload(Envelope envelope) {
    if (!envelope.isProcessable) {
      return Err(UnsupportedFutureVersion(envelope.version));
    }
    if (envelope.payload.length > ProtocolLimits.maxPayloadSize) {
      return Err(SizeLimitExceeded(
          envelope.payload.length, ProtocolLimits.maxPayloadSize));
    }
    try {
      switch (envelope.type) {
        case MessageType.chatEvent:
          return Ok(ChatEvent.fromBytes(envelope.payload));
        case MessageType.groupEvent:
          return Ok(GroupEvent.fromBytes(envelope.payload));
        case MessageType.syncRequest:
          return Ok(SyncRequest.fromBytes(envelope.payload));
        case MessageType.syncResponse:
          return Ok(SyncResponse.fromBytes(envelope.payload));
        case MessageType.fileChunk:
          return Ok(FileChunk.fromBytes(envelope.payload));
        case MessageType.fileRequest:
          return Ok(FileRequest.fromBytes(envelope.payload));
        case MessageType.presence:
          return Ok(Presence.fromBytes(envelope.payload));
        case MessageType.callControl:
          return Ok(CallControl.fromBytes(envelope.payload));
        case MessageType.relayFrame:
          return Ok(RelayFrame.fromBytes(envelope.payload));
        case MessageType.leaderLease:
          return Ok(LeaderLease.fromBytes(envelope.payload));
        case MessageType.unknown:
          return Err(UnknownMessageType(envelope.type.value));
        default:
          return Err(UnknownMessageType(envelope.type.value));
      }
    } on ProtocolError catch (e) {
      return Err(e);
    } catch (e, s) {
      return Err(DecodeError('payload decode failed: $e', s.toString()));
    }
  }
}
