import 'entity_id.dart';

/// Пользователь сети OpenSink.
/// Анонимная модель: открытый ключ Ed25519 выступает в роли UserId.
class User {
  const User({
    required this.id,
    required this.displayName,
    required this.avatarUrl,
    required this.createdAt,
  });

  final UserId id;
  final String displayName;
  final String? avatarUrl;
  final int createdAt; // Unix ms

  User copyWith({
    UserId? id,
    String? displayName,
    String? avatarUrl,
    int? createdAt,
  }) {
    return User(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is User && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'User(id=$id, displayName=$displayName)';
}
