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
    bool requireLocalAuthor = false,
  }) : _syncEngine = syncEngine,
       _controller = controller,
       _groupId = groupId,
       _codec = codec,
       _allowMissingGenesis = allowMissingGenesis,
       _requireLocalAuthor = requireLocalAuthor;

  final SyncEngineImpl _syncEngine;
  final GroupController _controller;
  final domain.GroupId _groupId;
  final GroupEventCodec _codec;

  /// Для join по инвайту genesis может ещё не прийти из sync.
  final bool _allowMissingGenesis;

  /// Для `created` genesis обязан быть подписан локальным ключом.
  final bool _requireLocalAuthor;

  final StreamController<domain.GroupState> _changes =
      StreamController<domain.GroupState>.broadcast();
  final Set<String> _rejected = <String>{};

  StreamSubscription<void>? _subscription;
  Future<void> _refreshTail = Future<void>.value();
  Future<void> _mutationTail = Future<void>.value();
  final Set<String> _verifiedEvents = <String>{};
  Future<domain.Result<void, GroupSyncError>>? _startAttempt;
  bool _started = false;
  bool _closed = false;
  bool _genesisValidated = false;
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
  /// До применения событий закрепляет доверенный genesis в движке и проверяет
  /// его. Чужие `GroupCreated` не принимаются конвейером и не блокируют группу.
  /// Для invite-пути отсутствие genesis допустимо до первого sync.
  ///
  /// `Ok` возвращается только после успешной проверки и применения истории;
  /// параллельные вызовы ожидают один и тот же результат.
  Future<domain.Result<void, GroupSyncError>> start() async {
    if (_closed) {
      return const domain.Err(MalformedGroupEvent('bridge is closed'));
    }
    final fatal = _fatalError;
    if (fatal != null) {
      return domain.Err(fatal);
    }
    if (_started) {
      return const domain.Ok(null);
    }
    final inFlight = _startAttempt;
    if (inFlight != null) {
      return inFlight;
    }
    final attempt = _start();
    _startAttempt = attempt;
    try {
      return await attempt;
    } finally {
      if (!_started) _startAttempt = null;
    }
  }

  Future<domain.Result<void, GroupSyncError>> _start() async {
    try {
      if (_fatalError != null) {
        return domain.Err(_fatalError!);
      }
      final pinned = await _syncEngine.pinGroupRoot(
        _groupId,
        _controller.genesisEventId,
      );
      if (pinned.isErr) {
        final error = pinned.unwrapErr();
        _fatalError = error is ForeignGroupRoot
            ? GenesisConflict(
                _controller.genesisEventId,
                domain.EventId(error.expected),
              )
            : SyncEngineFailure(error);
        return domain.Err(_fatalError!);
      }
      await _syncEngine.registerGroup(_groupId);

      _subscription = _syncEngine.changes.listen((_) {
        unawaited(_enqueueRefresh());
      });
      await _enqueueRefresh();
      if (_closed) {
        await _stopSubscription();
        return const domain.Err(MalformedGroupEvent('bridge is closed'));
      }
      final fatal = _fatalError;
      if (fatal != null) {
        await _stopSubscription();
        return domain.Err(fatal);
      }
      if (!_genesisValidated && !_allowMissingGenesis) {
        _fatalError = GenesisMissing(_groupId, _controller.genesisEventId);
        await _stopSubscription();
        return domain.Err(_fatalError!);
      }
      _started = true;
      return const domain.Ok(null);
    } on Object catch (error) {
      await _stopSubscription();
      return domain.Err(SyncEngineFailure(error));
    }
  }

  Future<void> _stopSubscription() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _enqueueRefresh() {
    final next = _refreshTail.then((_) => _serializedMutation(_refresh));
    _refreshTail = next.catchError((Object _) {});
    return next;
  }

  /// Сериализует изменения журнала и публикацию локальных событий.
  Future<T> _serializedMutation<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        result.complete(await action());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  /// Проверяет id и Ed25519-подпись до разбора payload.
  Future<bool> _isAuthentic(SyncEvent event) async {
    final id = event.id.value;
    if (id.isEmpty || id != event.computeId()) return false;
    if (_verifiedEvents.contains(id)) return true;
    final authorBytes = hexDecode(event.authorId.value);
    if (authorBytes == null || authorBytes.length != 32) return false;
    if (event.signature.isEmpty) return false;
    final valid = await _syncEngine.signer.verify(
      event.signedBytes(),
      event.signature,
      domain.PeerId(authorBytes),
    );
    if (valid) _verifiedEvents.add(id);
    return valid;
  }

  /// Публикует доменное событие и применяет его к контроллеру.
  ///
  /// Требует успешного [start] и отсутствия неустранимой ошибки корня. Для
  /// `GroupCreated` дополнительно публикует `MemberAdded` для начальных
  /// участников, потому что `core_sync` не разбирает `initialMembers`.
  Future<domain.Result<domain.GroupEvent, GroupSyncError>> publish(
    domain.GroupEvent draft,
  ) {
    return _serializedMutation(() => _publish(draft, requireStarted: true));
  }

  Future<domain.Result<domain.GroupEvent, GroupSyncError>> _publish(
    domain.GroupEvent draft, {
    required bool requireStarted,
  }) async {
    if (_closed) {
      return const domain.Err(MalformedGroupEvent('bridge is closed'));
    }
    final fatal = _fatalError;
    if (fatal != null) {
      return domain.Err(fatal);
    }
    if (requireStarted && !_started) {
      return const domain.Err(MalformedGroupEvent('bridge is not started'));
    }
    if (requireStarted && !_genesisValidated) {
      return const domain.Err(
        MalformedGroupEvent('trusted genesis is not validated'),
      );
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

    GroupSyncError? preflightError;
    final created = await _syncEngine.createEvent(
      groupId: _groupId,
      kind: kind,
      channelId: _codec.channelIdOf(draft),
      targetId: _codec.targetIdOf(draft),
      payload: payload.unwrap(),
      preflight: (syncEvent) {
        final decoded = _codec.decode(syncEvent);
        if (decoded.isErr) {
          preflightError = decoded.unwrapErr();
          return false;
        }
        final error = _controller.preflight(decoded.unwrap());
        if (error != null) {
          preflightError = ControllerFailure(error);
          return false;
        }
        return true;
      },
    );
    if (created.isErr) {
      final rejected = preflightError;
      if (rejected != null) return domain.Err(rejected);
      return domain.Err(SyncEngineFailure(created.unwrapErr()));
    }
    final syncEvent = created.unwrap();
    final fatalAfterCreate = _fatalError;
    if (fatalAfterCreate != null) return domain.Err(fatalAfterCreate);
    if (_closed) {
      return const domain.Err(MalformedGroupEvent('bridge is closed'));
    }
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
        await _publish(memberDraft, requireStarted: requireStarted);
      }
    }

    return domain.Ok(event);
  }

  /// Возвращает `true`, если доверенный genesis найден и проверен, и `false`
  /// если он ещё не пришёл (допустимо только для invite-пути).
  Future<domain.Result<bool, GroupSyncError>> _validateGenesis([
    List<SyncEvent>? cached,
  ]) async {
    final expectedId = _controller.genesisEventId;
    final events = cached ?? await _syncEngine.allEvents(_groupId);
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
      if (_allowMissingGenesis) return const domain.Ok(false);
      return domain.Err(GenesisMissing(_groupId, expectedId));
    }

    if (!await _isAuthentic(expected)) {
      return const domain.Err(
        InvalidGenesis('event id or signature is invalid'),
      );
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
    if (_requireLocalAuthor && event.authorId != _syncEngine.localAuthor) {
      return const domain.Err(InvalidGenesis('author is not local'));
    }
    if (!event.initialMembers.contains(event.ownerId)) {
      return const domain.Err(InvalidGenesis('owner is not a member'));
    }
    if (event.validateInvariants().isErr) {
      return const domain.Err(InvalidGenesis('invariants failed'));
    }
    return const domain.Ok(true);
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
        continue;
      }
      if (!await _isAuthentic(syncEvent)) continue;
      final decoded = _codec.decode(syncEvent);
      if (decoded.isErr) continue;
      groupEvents.add(decoded.unwrap());
    }
    if (!_genesisValidated &&
        events.any(
          (event) =>
              event.kind == SyncEventKind.groupCreated && event.id == genesisId,
        )) {
      final validated = await _validateGenesis(events);
      if (validated.isErr) {
        _fatalError = validated.unwrapErr();
        await _emit();
        return;
      }
      _genesisValidated = true;
    }
    groupEvents.sort(GroupState.compareEvents);
    var changed = false;
    for (final event in groupEvents) {
      if (_closed || _fatalError != null) return;
      if (event is domain.GroupCreated && event.id != genesisId) continue;
      final existing = _controller.event(event.id);
      if (existing != null && GroupState.compareBodies(event, existing) >= 0) {
        continue;
      }
      if (_rejected.contains(event.id.value)) continue;
      final applied = await _controller.apply(event);
      changed = true;
      if (applied.isErr) {
        final error = applied.unwrapErr();
        if (event is domain.GroupCreated && event.id == genesisId) {
          _fatalError = InvalidGenesis(
            'trusted genesis failed to apply: $error',
          );
          await _emit();
          return;
        }
        if (_isPermanent(error)) {
          _rejected.add(event.id.value);
        }
      }
    }
    if (changed) await _emit();
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
      pendingJoins: Map<domain.UserId, String>.unmodifiable(
        source.pendingJoins,
      ),
      createdAt: source.createdAt,
      updatedAt: source.updatedAt,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _started = false;
    _startAttempt = null;
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
    final members = {...?initialMembers, owner};
    final draft = domain.GroupCreated(
      id: const domain.EventId(''),
      groupId: groupId,
      authorId: owner,
      timestamp: 0,
      name: name,
      ownerId: owner,
      initialMembers: members,
    );
    final invalid = draft.validateInvariants();
    if (invalid.isErr) {
      return domain.Err(MalformedGroupEvent(invalid.unwrapErr().toString()));
    }
    if (groupId.value.isEmpty) {
      return const domain.Err(MalformedGroupEvent('groupId is empty'));
    }
    for (final member in members) {
      final key = hexDecode(member.value);
      if (key == null || key.length != 32) {
        return const domain.Err(
          MalformedGroupEvent('initial member is not 64-hex'),
        );
      }
    }
    final payload = codec.encode(draft);
    if (payload.isErr) return domain.Err(payload.unwrapErr());
    GroupSyncError? pinError;
    final created = await syncEngine.createEvent(
      groupId: groupId,
      kind: SyncEventKind.groupCreated,
      payload: payload.unwrap(),
      beforeIngest: (syncEvent) async {
        final pinned = await syncEngine.pinGroupRoot(groupId, syncEvent.id);
        if (pinned.isErr) {
          pinError = SyncEngineFailure(pinned.unwrapErr());
          return false;
        }
        return true;
      },
    );
    if (created.isErr) {
      final rejected = pinError;
      if (rejected != null) return domain.Err(rejected);
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
      requireLocalAuthor: true,
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
      final result = await bridge._publish(memberDraft, requireStarted: false);
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
