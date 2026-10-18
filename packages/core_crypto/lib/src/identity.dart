import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart;

/// Конкретная реализация доменной [Identity] с закрытым ключом Ed25519.
///
/// Закрытый ключ никогда не покидает [SecureKeyStore] и не логируется.
class CryptoIdentity extends Identity {
  const CryptoIdentity({
    required super.peerId,
    required super.userId,
    required this.publicKey,
    required this.privateKey,
  });

  /// Открытый ключ Ed25519.
  final PublicKey publicKey;

  /// Закрытый ключ Ed25519.
  final SecretKey privateKey;

  @override
  Map<String, Object?> toPublicMap() => {
        'peerId': publicKey.hex,
        'userId': userId.value,
      };

  @override
  String toString() => 'CryptoIdentity(userId=${userId.value}, publicKey=${publicKey.hex})';
}

/// Сгенерировать новую Ed25519 идентичность.
Future<CryptoIdentity> generateIdentity() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  return CryptoIdentity(
    peerId: PeerId(keyPair.publicKey.bytes),
    userId: UserId(keyPair.publicKey.hex),
    publicKey: keyPair.publicKey,
    privateKey: keyPair.privateKey,
  );
}
