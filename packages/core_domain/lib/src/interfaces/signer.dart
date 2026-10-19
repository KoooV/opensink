import 'dart:typed_data';

import '../models/identifiers.dart';

/// Интерфейс подписчика / верификатора Ed25519.
///
/// Реализация в [core_crypto] (package:cryptography). Все подписные операции
/// детерминированы; секреты не попадают в логи.
abstract class Signer {
  /// Подписывает байты закрытым ключом. Возвращает hex-подпись.
  Future<String> sign(Uint8List data);

  /// Верифицирует hex-подпись по открытому ключу.
  Future<bool> verify(Uint8List data, String signatureHex, PeerId peerId);
}
