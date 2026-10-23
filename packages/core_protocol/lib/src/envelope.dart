import 'dart:typed_data';

import 'limits.dart';
import 'message_type.dart';
import 'wire.dart';

/// Конверт протокола OpenSink.
///
/// Поля:
///   version  — версия протокола (uint32)
///   type     — тип вложенного сообщения (int32, MessageType)
///   sender   — открытый ключ Ed25519 отправителя (bytes)
///   hlc      — гибридные логические часы (uint64)
///   payload  — сериализованное вложенное сообщение (bytes)
///   signature — Ed25519-подпись над signatureData() (bytes)
class Envelope {
  Envelope({
    required this.version,
    required this.type,
    required this.sender,
    required this.hlc,
    required this.payload,
    required this.signature,
    this._unknownFields = const <int, Uint8List>{},
  });

  final int version;
  final MessageType type;
  final Uint8List sender;
  final int hlc;
  final Uint8List payload;
  final Uint8List signature;
  final Map<int, Uint8List> _unknownFields;

  /// Поля, не распознанные текущей версией протокола.
  ///
  /// Сохраняются и могут быть пересланы дальше (прямая совместимость).
  ///
  /// ⚠ Доверие: неизвестные поля НЕ входят в зону подписи
  /// ([signatureData] подписывает поля 1–4 + payload). Это позволяет
  /// релеям вставлять маршрутную метаданные без поломки подписи, но
  /// делает неизвестные поля неаутентифицированными. Текущая версия
  /// не должна принимать решения о доставке, основываясь на их
  /// содержимом — только хранить и пересылать байт-в-байт.
  Map<int, Uint8List> get unknownFields => _unknownFields;

  /// Может ли этот узел полностью обработать конверт (верифицировать,
  /// распарсить payload и доставить локально).
  ///
  /// Конверты с version > [ProtocolLimits.maxSupportedVersion]
  /// декодируются структурно и могут быть пересланы релеем, но
  /// семантически не обрабатываются (`codec.decodePayload` вернёт
  /// `UnsupportedFutureVersion`).
  bool get isProcessable => version <= ProtocolLimits.maxSupportedVersion;

  /// Копия с заменой полей.
  Envelope copyWith({
    int? version,
    MessageType? type,
    Uint8List? sender,
    int? hlc,
    Uint8List? payload,
    Uint8List? signature,
    Map<int, Uint8List>? unknownFields,
  }) {
    return Envelope(
      version: version ?? this.version,
      type: type ?? this.type,
      sender: sender ?? this.sender,
      hlc: hlc ?? this.hlc,
      payload: payload ?? this.payload,
      signature: signature ?? this.signature,
      unknownFields: unknownFields ?? _unknownFields,
    );
  }

  /// Сериализует конверт в байты protobuf (включая signature, если есть).
  void writeTo(ProtoWriter writer) {
    writer.writeVarintField(1, version);
    writer.writeVarintField(2, type.value);
    writer.writeBytesField(3, sender);
    writer.writeVarintField(4, hlc);
    writer.writeBytesField(5, payload);
    if (signature.isNotEmpty) {
      writer.writeBytesField(6, signature);
    }
    writer.writeUnknownFields(_unknownFields);
  }

  /// Байты конверта.
  Uint8List toBytes() {
    final writer = ProtoWriter();
    writeTo(writer);
    return writer.finish();
  }

  /// Десериализует конверт из байтов.
  static Envelope fromBytes(Uint8List bytes) {
    final reader = ProtoReader(bytes);
    return fromReader(reader);
  }

  /// Десериализует конверт из [ProtoReader].
  static Envelope fromReader(ProtoReader reader) {
    int version = ProtocolLimits.currentVersion;
    int typeValue = MessageType.unknown.value;
    final sender = <int>[];
    int hlc = 0;
    final payload = <int>[];
    final signature = <int>[];
    final unknown = <int, Uint8List>{};

    while (true) {
      final start = reader.mark();
      final tag = reader.readTag();
      if (tag == null) {
        break;
      }
      final (fieldNumber, wireType) = tag;
      switch (fieldNumber) {
        case 1:
          version = reader.readVarint();
          break;
        case 2:
          typeValue = reader.readVarint();
          break;
        case 3:
          reader.readBytes().forEach(sender.add);
          break;
        case 4:
          hlc = reader.readVarint();
          break;
        case 5:
          reader.readBytes().forEach(payload.add);
          break;
        case 6:
          reader.readBytes().forEach(signature.add);
          break;
        default:
          reader.consumeField(wireType);
          unknown[fieldNumber] = reader.slice(start, reader.position);
          break;
      }
    }

    return Envelope(
      version: version,
      type: MessageType.fromInt(typeValue),
      sender: Uint8List.fromList(sender),
      hlc: hlc,
      payload: Uint8List.fromList(payload),
      signature: Uint8List.fromList(signature),
      unknownFields: unknown,
    );
  }

  /// Данные для подписи: заголовок (поля 1–4) + payload.
  ///
  /// Поле signature сам в подпись не входит (циклическая зависимость).
  ///
  /// ⚠ Неизвестные поля ([unknownFields]) intentionally НЕ входят в
  /// зону подписи, чтобы релеи могли добавлять маршрутную метаданные
  /// без инвалидации подписи. Соответственно, они не аутентифицированы
  /// и не должны влиять на решения о доставке.
  Uint8List signatureData() {
    final writer = ProtoWriter();
    writer.writeVarintField(1, version);
    writer.writeVarintField(2, type.value);
    writer.writeBytesField(3, sender);
    writer.writeVarintField(4, hlc);
    final header = writer.finish();
    return Uint8List.fromList([...header, ...payload]);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Envelope &&
          runtimeType == other.runtimeType &&
          version == other.version &&
          type == other.type &&
          _bytesEquals(sender, other.sender) &&
          hlc == other.hlc &&
          _bytesEquals(payload, other.payload) &&
          _bytesEquals(signature, other.signature) &&
          _mapEquals(_unknownFields, other._unknownFields);

  @override
  int get hashCode {
    var result = version.hashCode;
    result ^= type.hashCode;
    result ^= sender.hashCode;
    result ^= hlc.hashCode;
    result ^= payload.hashCode;
    result ^= signature.hashCode;
    result ^= _unknownFields.hashCode;
    return result;
  }

  @override
  String toString() =>
      'Envelope(version=$version, type=$type, senderLen=${sender.length}, '
      'hlc=$hlc, payloadLen=${payload.length}, signatureLen=${signature.length})';
}

bool _bytesEquals(Uint8List? a, Uint8List? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEquals(Map<int, Uint8List> a, Map<int, Uint8List> b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    final bValue = b[key];
    if (bValue == null) return false;
    if (!_bytesEquals(a[key], bValue)) return false;
  }
  return true;
}
