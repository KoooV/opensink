import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:meta/meta.dart';

/// Пакет нового sender key для доставки оставшимся участникам.
@immutable
class GroupKeyRotation {
  const GroupKeyRotation({
    required this.groupId,
    required this.epoch,
    required this.sender,
    required this.recipients,
    required this.keyPackage,
  });

  final GroupId groupId;
  final int epoch;
  final UserId sender;
  final Set<UserId> recipients;
  final Uint8List keyPackage;

  @override
  String toString() =>
      'GroupKeyRotation(groupId=$groupId, epoch=$epoch, '
      'recipients=${recipients.length}, keyPackage=<hidden>)';
}

/// Доставка новых sender keys по E2E-зашифрованным личным сообщениям.
abstract class GroupKeyDistributor {
  Future<void> distribute(GroupKeyRotation rotation);
}

/// In-memory fake для тестов: запоминает ротации, ничего не шифрует.
class InMemoryGroupKeyDistributor implements GroupKeyDistributor {
  final _rotations = <GroupKeyRotation>[];

  List<GroupKeyRotation> get rotations => List.unmodifiable(_rotations);

  @override
  Future<void> distribute(GroupKeyRotation rotation) async {
    _rotations.add(rotation);
  }
}
