import 'package:cryptography/cryptography.dart';
import 'package:core_domain/core_domain.dart';

/// Идентичность пользователя в сети OpenSink.
///
/// Открытый ключ Ed25519 является UserId. Закрытый ключ никогда не покидает
/// SecureKeyStore и не логируется.
class Identity {
  const Identity({
    required this.userId,
    required this.publicKey,
    required this.privateKey,
  });

  final UserId userId;
  final PublicKey publicKey;
  final SecretKey privateKey;

  /// Сериализует открытую часть идентичности (без секрета).
  IdentityBundle toBundle(List<int> encryptedPrivateKey) => IdentityBundle(
        userId: userId,
        publicKey: publicKey.hex,
        encryptedPrivateKey: encryptedPrivateKey,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

  @override
  String toString() => 'Identity(userId=${userId.value}, publicKey=${publicKey.hex})';
}

/// Сгенерировать новую Ed25519 идентичность.
Future<Identity> generateIdentity() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  return Identity(
    userId: UserId(keyPair.publicKey.hex),
    publicKey: keyPair.publicKey,
    privateKey: keyPair.privateKey,
  );
}

/// Пакет для хранения в SecureKeyStore (секрет зашифрован).
@immutable
class IdentityBundle {
  const IdentityBundle({
    required this.userId,
    required this.publicKey,
    required this.encryptedPrivateKey,
    required this.createdAt,
  });

  final UserId userId;
  final String publicKey;
  final List<int> encryptedPrivateKey;
  final int createdAt;
}
