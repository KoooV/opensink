/// Роль участника группы. Ранг задаёт старшинство при проверке прав.
enum GroupRole {
  member,
  moderator,
  admin,
  owner;

  /// Чем больше значение, тем больше прав.
  int get rank => index;

  bool atLeast(GroupRole other) => rank >= other.rank;
}
