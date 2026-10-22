import '../models/identifiers.dart';

/// Доменная модель идентичности пользователя.
///
/// Конкретная реализация (с закрытым ключом в SecureKeyStore) находится в
/// `core_crypto`. В домене — только контракт.
abstract class Identity {
  /// Идентификатор узла — открытый ключ Ed25519.
  PeerId get peerId;

  /// Пользователь (UserId — hex открытого ключа).
  UserId get userId;

  /// Сериализует открытую часть идентичности (без секрета).
  Map<String, Object?> toPublicMap();
}
