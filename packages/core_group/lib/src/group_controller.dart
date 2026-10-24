import 'dart:async';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide GroupState;

import 'group_error.dart';
import 'group_state.dart';
import 'invite_proof.dart';
import 'key_distributor.dart';

/// Применение событий с побочным эффектом доставки новых sender keys.
///
/// Контроллер хранит журнал событий и пересчитывает проекцию детерминированно
/// при каждом `apply`: порядок доставки и форки не влияют на итог. Сама
/// проекция остаётся чистой.
class GroupController {
  GroupController({
    required this.distributor,
    required this.expectedGroupId,
    required this.genesisEventId,
    this.inviteProofVerifier,
    this.maxJournalEvents = 4096,
  });

  final GroupKeyDistributor distributor;
  final GroupId expectedGroupId;
  final EventId genesisEventId;
  final InviteProofVerifier? inviteProofVerifier;

  /// Верхняя граница журнала, чтобы поток orphan-событий не рос бесконечно.
  final int maxJournalEvents;

  final Map<String, GroupEvent> _events = {};
  GroupState _state = const GroupState.empty();
  Future<void> _tail = Future<void>.value();

  GroupState get state => _state;

  /// Событие из журнала контроллера по id (для моста с `core_sync`).
  GroupEvent? event(EventId id) => _events[id.value];

  Future<Result<GroupState, GroupError>> apply(
    GroupEvent event, {
    UserId? localPeerId,
    Uint8List? keyPackage,
  }) {
    final completer = Completer<Result<GroupState, GroupError>>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(
          await _apply(event, localPeerId: localPeerId, keyPackage: keyPackage),
        );
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<Result<GroupState, GroupError>> _apply(
    GroupEvent event, {
    UserId? localPeerId,
    Uint8List? keyPackage,
  }) async {
    final rejected = _rejectPermanently(event);
    if (rejected != null) return Err(rejected);

    final key = event.id.value;
    final previous = _events[key];
    final shouldStore = previous == null || _prefer(event, previous);
    if (previous == null && _events.length >= maxJournalEvents) {
      return const Err(JournalFull());
    }
    if (shouldStore) _events[key] = event;

    final before = _state;
    final replay = GroupState.replay(
      _events.values,
      expectedGroupId: expectedGroupId,
      genesisEventId: genesisEventId,
      inviteProofVerifier: inviteProofVerifier,
    );
    final after = replay.state;

    if (after.keyEpoch < before.keyEpoch) {
      if (shouldStore) {
        if (previous == null) {
          _events.remove(key);
        } else {
          _events[key] = previous;
        }
      }
      return const Err(StateRegression());
    }

    _state = after;

    if (after.keyEpoch > before.keyEpoch) {
      final rotationEvent = replay.epochEvents[after.keyEpoch];
      if (rotationEvent != null) {
        await _distribute(
          before: before,
          after: after,
          rotationEvent: rotationEvent,
          incoming: event,
          localPeerId: localPeerId,
          keyPackage: keyPackage,
        );
      }
    }

    final error = replay.errorFor(event.id);
    if (error != null) {
      if (event is GroupCreated && !after.isInitialized) return Err(error);
      // Событие уже принято в журнал: будущие события с меньшим HLC могут
      // изменить результат. Err только для детерминированно невалидных тел.
      return _isPermanentError(error) ? Err(error) : Ok(after);
    }
    if (replay.processedEventIds.contains(event.id)) return Ok(after);
    if (event is GroupCreated &&
        event.id == genesisEventId &&
        after.isInitialized) {
      return Ok(after);
    }
    if (!after.isInitialized && event is! GroupCreated) return Ok(after);
    if (!_hasFullAncestry(event)) return Ok(after);
    return const Err(EventChainBroken());
  }

  bool _isPermanentError(GroupError error) =>
      error is InvalidKeyEpoch ||
      error is InviteProofRequired ||
      error is InvalidInviteProof;

  GroupError? _rejectPermanently(GroupEvent event) {
    if (event is RoleSet && event.role == GroupRole.owner) {
      return const OwnerRoleNotAssignable();
    }
    final invariants = event.validateInvariants();
    if (invariants.isErr) return InvalidEvent(invariants.unwrapErr());

    if (_state.isInitialized) {
      if (event.groupId != _state.id) return const GroupIdMismatch();
      if (event is GroupCreated && event.id != genesisEventId) {
        return const AlreadyInitialized();
      }
      return null;
    }
    if (event.groupId != expectedGroupId) return const GroupIdMismatch();
    if (event is GroupCreated && event.id != genesisEventId) {
      return const GenesisMismatch();
    }
    return null;
  }

  bool _prefer(GroupEvent incoming, GroupEvent existing) {
    if (incoming is GroupCreated && incoming.id == genesisEventId) {
      final incomingValid = _validGenesis(incoming);
      final existingValid = _validGenesis(existing);
      if (incomingValid != existingValid) return incomingValid;
    }
    return GroupState.compareBodies(incoming, existing) < 0;
  }

  bool _validGenesis(GroupEvent event) =>
      event is GroupCreated &&
      event.id == genesisEventId &&
      event.groupId == expectedGroupId &&
      event.authorId == event.ownerId &&
      event.validateInvariants().isOk;

  bool _hasFullAncestry(GroupEvent event) {
    GroupEvent? current = event;
    final seen = <String>{};
    while (current != null) {
      final prev = current.prevId;
      if (prev == null) return true;
      if (prev == genesisEventId) {
        return _state.isInitialized || _events.containsKey(prev.value);
      }
      if (!seen.add(prev.value)) return true;
      current = _events[prev.value];
      if (current == null) return false;
    }
    return true;
  }

  Future<void> _distribute({
    required GroupState before,
    required GroupState after,
    required GroupEvent rotationEvent,
    required GroupEvent incoming,
    UserId? localPeerId,
    Uint8List? keyPackage,
  }) async {
    final previousEpoch = before.isInitialized ? before.keyEpoch : 1;
    if (after.keyEpoch <= previousEpoch) return;

    final sender = localPeerId != null && localPeerId == rotationEvent.authorId
        ? localPeerId
        : rotationEvent.authorId;
    final recipients = after.members.keys
        .where((member) => member != sender)
        .toSet();
    await distributor.distribute(
      GroupKeyRotation(
        groupId: after.id,
        epoch: after.keyEpoch,
        sender: sender,
        recipients: recipients,
        keyPackage: rotationEvent.id == incoming.id
            ? keyPackage ?? Uint8List(0)
            : Uint8List(0),
      ),
    );
  }
}
