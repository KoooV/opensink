import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide GroupState;

import 'group_error.dart';
import 'group_state.dart';
import 'invite_proof.dart';
import 'key_distributor.dart';

/// Применение событий с побочным эффектом доставки новых sender keys.
///
/// Сама проекция остаётся чистой; контроллер лишь реагирует на рост эпохи.
class GroupController {
  GroupController({
    required this.distributor,
    required this.expectedGroupId,
    required this.genesisEventId,
    this.inviteProofVerifier,
  });

  final GroupKeyDistributor distributor;
  final GroupId expectedGroupId;
  final EventId genesisEventId;
  final InviteProofVerifier? inviteProofVerifier;

  GroupState _state = const GroupState.empty();

  GroupState get state => _state;

  Future<Result<GroupState, GroupError>> apply(
    GroupEvent event, {
    UserId? localPeerId,
    Uint8List? keyPackage,
  }) async {
    final before = _state;
    final result = before.apply(
      event,
      inviteProofVerifier: inviteProofVerifier,
      expectedGroupId: expectedGroupId,
      genesisEventId: genesisEventId,
    );
    if (result.isErr) return result;

    final after = result.unwrap();
    _state = after;

    if (before.isInitialized && after.keyEpoch > before.keyEpoch) {
      final sender = localPeerId ?? event.authorId;
      final recipients = after.members.keys
          .where((member) => member != sender)
          .toSet();
      await distributor.distribute(
        GroupKeyRotation(
          groupId: after.id,
          epoch: after.keyEpoch,
          sender: sender,
          recipients: recipients,
          keyPackage: keyPackage ?? Uint8List(0),
        ),
      );
    }

    return Ok<GroupState, GroupError>(after);
  }
}
