// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:core_domain/core_domain.dart' as domain;
import 'package:core_sync/core_sync.dart';

import 'group_controller.dart';
import 'group_error.dart';
import 'group_event_codec.dart';
import 'group_state.dart';
import 'invite_proof.dart';
import 'key_distributor.dart';

/// Мост между административными событиями `core_group` и логом `core_sync`.
///
/// Публикует доменные события как подписанные `SyncEvent` и применяет
/// проверенные события из лога к [GroupController]. Реализует интерфейс IGroupState
/// для подписки UI на публичное состояние группы.
class GroupSyncBridge implements domain.IGroupState {
  GroupSyncBridge({
    required SyncEngineImpl syncEngine,
    required GroupController controller,
    required domain.GroupId groupId,
    GroupEventCodec codec = const GroupEventCodec(),
    bool allowMissingGenesis = false,
  }) : _syncEngine = syncEngine,
       _controller = controller,
       _groupId = groupId,
       _codec = codec,
       _allowMissingGenesis = allowMissingGenesis;

  final SyncEngineImpl _syncEngine;
  final GroupController _controller;
  final domain.GroupId _groupId;
  final GroupEventCodec _codec;

  /// Для join по инвайту genesis может ещё не прийти из sync.
  final bool _allowMissingGenesis;

  final StreamController<domain.GroupState> _changes =
      StreamController<domain.GroupState>.broadcast();
  final Set<String> _rejected = <String>{};

  StreamSubscription<void>? _subscription;
  Future<void> _refreshTail = Future<void>.value();
  bool _started = false;
  bool _closed = false;
  GroupSyncError? _fatalError;

  @override
  domain.GroupState get state => _toPublicState(_controller.state);

  @override
  Stream<domain.GroupState> watch() => _changes.stream;

  /// Доверенный genesis, зафиксированный в контроллере.
  domain.EventId get genesisEventId => _controller.genesisEventId;

  /// Неустранимый конфликт корня, обнаруженный после старта.
  GroupSyncError? get fatalError => _fatalError;

  /// Следующий `prevId` для локального административного события.
  domain.EventId? get nextPrevId =>
      _controller.state.cursors[_syncEngine.localAuthor]?.id;

  /// Подписывается на изменения `SyncEngine` и применяет текущую историю.
  ///
  /// До применения событий проверяет доверенный genesis. Если в логе есть
  /// другой `GroupCreated`, возвращает [GenesisConflict] и не применяет
  /// историю. Для invite-пути отсутствие genesis допустимо.
  Future<domain.Result<void, GroupSyncError>> start() async {
    if (_fatalError != null) {
      return domain.Err(_fatalError!);
    }
    if (_started) {
      return const domain.Ok(null);
    }
    if (_closed) {
      return const domain.Err(MalformedGroupEvent('bridge is closed'));
    }
    _started = true;
    await _syncEngine.registerGroup(_groupId);
    final validated = await _validateGenesis();
    if (validated.isErr) {
      _started = false;
      _fatalError = validated.unwrapErr();
      return domain.Err(_fatalError!);
    }
    await _refresh();
    if (_fatalError != null) {
      _started = false;
      return domain.Err(_fatalError!);
    }
    _subscription = _syncEngine.changes.listen((_) {
      _refreshTail = _refreshTail.then((_) => _refresh());
    });
    return const domain.Ok(null);
  }

  /// Публикует доменное событие и применяет его к контроллеру.
  ///
  /// Для `GroupCreated` дополнительно публикует `MemberAdded` для начальных
  /// участников, потому что `core_sync` не разбирает `initialMembers`.
  Future<domain.Result<domain.GroupEvent, GroupSyncError>> publish(
    domain.GroupEvent draft,
  ) async {
    if (_closed) {
      return const domain.Err(MalformedGroupEvent('bridge is closed'));
    }
    if (draft.groupId != _groupId) {
      return domain.Err(GroupIdMismatchError(_groupId, draft.groupId));
    }
    if (draft.authorId != _syncEngine.localAuthor) {
      return domain.Err(
        GroupAuthorMismatch(_syncEngine.localAuthor, draft.authorId),
      );
    }
    final expectedPrev = _controller.state.cursors[draft.authorId]?.id;
    if (draft.prevId != expectedPrev) {
      return const domain.Err(
        MalformedGroupEvent('prevId does not match group journal cursor'),
      );
    }

    final kind = _codec.kindOf(draft);
    final payload = _codec.encode(draft);
    if (payload.isErr) return domain.Err(payload.unwrapErr());

    final created = await _syncEngine.createEvent(
      groupId: _groupId,
      kind: kind,
      channelId: _codec.channelIdOf(draft),
      targetId: _codec.targetIdOf(draft),
      payload: payload.unwrap(),
    );
    if (created.isErr) {
      return domain.Err(SyncEngineFailure(created.unwrapErr()));
    }
    final syncEvent = created.unwrap();
    final decoded = _codec.decode(syncEvent);
    if (decoded.isErr) return domain.Err(decoded.unwrapErr());
    final event = decoded.unwrap();

    final applied = await _controller.apply(event);
    if (applied.isErr) {
      return domain.Err(ControllerFailure(applied.unwrapErr()));
    }
    await _emit();

    if (event is domain.GroupCreated) {
      for (final member in event.initialMembers) {
        if (member == event.ownerId) continue;
        final prev = _controller.state.cursors[event.authorId]?.id;
        final memberDraft = domain.MemberAdded(
          id: const domain.EventId(''),
          groupId: _groupId,
          authorId: event.authorId,
          timestamp: event.timestamp,
          counter: event.counter,
          prevId: prev,
          userId: member,
        );
        await publish(memberDraft);
      }
    }

    return domain.Ok(event);
  }

  Future<domain.Result<void, GroupSyncError>> _validateGenesis() async {
    final expectedId = _controller.genesisEventId;
    final events = await _syncEngine.allEvents(_groupId);
    SyncEvent? expected;
    domain.EventId? conflict;
    for (final event in events) {
      if (event.kind != SyncEventKind.groupCreated) continue;
      if (event.id == expectedId) {
        expected = event;
      } else {
        conflict ??= event.id;
      }
    }
    if (conflict != null) {
      return domain.Err(GenesisConflict(expectedId, conflict));
    }
    if (expected == null) {
      if (_allowMissingGenesis) return const domain.Ok(null);
      return domain.Err(GenesisMissing(_groupId, expectedId));
    }

    final decoded = _codec.decode(expected);
    if (decoded.isErr) {
      return domain.Err(InvalidGenesis(decoded.unwrapErr().toString()));
    }
    final event = decoded.unwrap();
    if (event is! domain.GroupCreated) {
      return const domain.Err(InvalidGenesis('not a GroupCreated event'));
    }
    if (event.groupId != _groupId) {
      return const domain.Err(InvalidGenesis('groupId mismatch'));
    }
    if (event.authorId != event.ownerId) {
      return const domain.Err(InvalidGenesis('author is not owner'));
    }
    if (!event.initialMembers.contains(event.ownerId)) {
      return const domain.Err(InvalidGenesis('owner is not a member'));
    }
    if (event.validateInvariants().isErr) {
      return const domain.Err(InvalidGenesis('invariants failed'));
    }
    if (expected.id.value != expected.computeId()) {
      return const domain.Err(InvalidGenesis('event id does not match body'));
    }
    final authorBytes = hexDecode(expected.authorId.value);
    if (authorBytes == null || authorBytes.length != 32) {
      return const domain.Err(InvalidGenesis('invalid author key'));
    }
    if (expected.signature.isEmpty) {
      return const domain.Err(InvalidGenesis('missing signature'));
    }
    final signatureValid = await _syncEngine.signer.verify(
      expected.signedBytes(),
      expected.signature,
      domain.PeerId(authorBytes),
    );
    if (!signatureValid) {
      return const domain.Err(InvalidGenesis('invalid signature'));
    }
    return const domain.Ok(null);
  }

  Future<void> _refresh() async {
    if (_closed || _fatalError != null) return;
    final events = await _syncEngine.allEvents(_groupId);
    final groupEvents = <domain.GroupEvent>[];
    final genesisId = _controller.genesisEventId;
    for (final syncEvent in events) {
      if (!_codec.isGroupEventKind(syncEvent.kind)) continue;
      if (syncEvent.kind == SyncEventKind.groupCreated &&
          syncEvent.id != genesisId) {
        _fatalError = GenesisConflict(genesisId, syncEvent.id);
        return;
      }
      final decoded = _codec.decode(syncEvent);
      if (decoded.isErr) continue;
      groupEvents.add(decoded.unwrap());
    }
    groupEvents.sort(GroupState.compareEvents);
    for (final event in groupEvents) {
      if (_closed || _fatalError != null) return;
      if (event is domain.GroupCreated && event.id != genesisId) {
        _fatalError = GenesisConflict(genesisId, event.id);
        return;
      }
      final existing = _controller.event(event.id);
      if (existing != null && GroupState.compareBodies(event, existing) >= 0) {
        continue;
      }
      if (_rejected.contains(event.id.value)) continue;
      final applied = await _controller.apply(event);
      if (applied.isErr && _isPermanent(applied.unwrapErr())) {
        _rejected.add(event.id.value);
      }
    }
    await _emit();
  }

  bool _isPermanent(GroupError error) =>
      error is InvalidEvent || error is OwnerRoleNotAssignable;

  Future<void> _emit() async {
    if (_closed) return;
    _changes.add(_toPublicState(_controller.state));
  }

  domain.GroupState _toPublicState(GroupState source) {
    return domain.GroupState(
      id: source.id,
      name: source.name,
      ownerId: source.ownerId,
      memberIds: source.members.keys.toSet(),
      channelIds: source.channels.keys.toSet(),
      createdAt: source.createdAt,
      updatedAt: source.updatedAt,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _changes.close();
  }

  /// Создаёт группу, контроллер и мост за один шаг.
  ///
  /// Сначала публикуется `GroupCreated`, затем контроллер фиксирует его id как
  /// `genesisEventId`, после чего публикуются `MemberAdded` для остальных
  /// начальных участников.
  static Future<domain.Result<GroupSyncBridge, GroupSyncError>> create({
    required SyncEngineImpl syncEngine,
    required domain.GroupId groupId,
    required String name,
    Set<domain.UserId>? initialMembers,
    required GroupKeyDistributor distributor,
    InviteProofVerifier? inviteProofVerifier,
    int maxJournalEvents = 4096,
    GroupEventCodec codec = const GroupEventCodec(),
  }) async {
    final owner = syncEngine.localAuthor;
    final members = initialMembers ?? {owner};
    if (members.isEmpty) {
      return const domain.Err(MalformedGroupEvent('initial members are empty'));
    }
    final draft = domain.GroupCreated(
      id: const domain.EventId(''),
      groupId: groupId,
      authorId: owner,
      timestamp: 0,
      name: name,
      ownerId: owner,
      initialMembers: members,
    );
    final payload = codec.encode(draft);
    if (payload.isErr) return domain.Err(payload.unwrapErr());
    final created = await syncEngine.createEvent(
      groupId: groupId,
      kind: SyncEventKind.groupCreated,
      payload: payload.unwrap(),
    );
    if (created.isErr) {
      return domain.Err(SyncEngineFailure(created.unwrapErr()));
    }
    final syncEvent = created.unwrap();
    final controller = GroupController(
      distributor: distributor,
      expectedGroupId: groupId,
      genesisEventId: syncEvent.id,
      inviteProofVerifier: inviteProofVerifier,
      maxJournalEvents: maxJournalEvents,
    );
    final bridge = GroupSyncBridge(
      syncEngine: syncEngine,
      controller: controller,
      groupId: groupId,
      codec: codec,
    );
    final decoded = codec.decode(syncEvent);
    if (decoded.isErr) {
      await bridge.close();
      return domain.Err(decoded.unwrapErr());
    }
    final applied = await controller.apply(decoded.unwrap());
    if (applied.isErr) {
      await bridge.close();
      return domain.Err(ControllerFailure(applied.unwrapErr()));
    }
    for (final member in members) {
      if (member == owner) continue;
      final prev = controller.state.cursors[owner]?.id;
      final memberDraft = domain.MemberAdded(
        id: const domain.EventId(''),
        groupId: groupId,
        authorId: owner,
        timestamp: 0,
        prevId: prev,
        userId: member,
      );
      final result = await bridge.publish(memberDraft);
      if (result.isErr) {
        await bridge.close();
        return domain.Err(result.unwrapErr());
      }
    }
    final started = await bridge.start();
    if (started.isErr) {
      await bridge.close();
      return domain.Err(started.unwrapErr());
    }
    return domain.Ok(bridge);
  }
}
