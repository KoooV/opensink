import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';

import 'key_distributor.dart';
import 'sender_key_package_codec.dart';

/// Личный E2E-канал доставки sender-key пакетов.
///
/// Реализация обязана аутентифицировать и шифровать payload для recipient
/// (Double Ratchet/X3DH). `core_group` не знает формат сессии и
/// не отправляет ключевой пакет в групповой лог.
abstract class SenderKeyChannel {
  Future<Result<void, SenderKeyDeliveryError>> send(
    UserId recipient,
    Uint8List payload,
  );
}

/// Fail-closed канал: пока личная E2E-сессия не установлена.
class UnavailableSenderKeyChannel implements SenderKeyChannel {
  const UnavailableSenderKeyChannel();

  @override
  Future<Result<void, SenderKeyDeliveryError>> send(
    UserId recipient,
    Uint8List payload,
  ) async {
    return const Err(SenderKeyDeliveryRejected('E2E channel unavailable'));
  }
}

/// Доставка подписанного пакета через [SenderKeyChannel].
class E2eSenderKeyDelivery implements SenderKeyDelivery {
  const E2eSenderKeyDelivery({
    required this.channel,
    this.codec = const SenderKeyPackageCodec(),
  });

  final SenderKeyChannel channel;
  final SenderKeyPackageCodec codec;

  @override
  Future<Result<void, SenderKeyDeliveryError>> deliver(
    SenderKeyPackage package,
  ) async {
    final signature = package.signature;
    if (signature == null || signature.isEmpty) {
      return const Err(
        SenderKeyDeliveryRejected('sender key package is not signed'),
      );
    }
    return channel.send(package.recipient, codec.encode(package));
  }
}
