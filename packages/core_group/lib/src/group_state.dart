import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:meta/meta.dart';

import 'group_error.dart';
import 'invite_proof.dart';

/// Канал группы с минимальными ролями доступа.
@immutable
class GroupChannel {
  const GroupChannel({
    required this.id,
    required this.name,
    required this.type,
    required this.minViewRole,
    required this.minPostRole,
    required this.createdBy,
    required this.createdAt,
  });

  final ChannelId id;
  final String name;
  final String type;
  final GroupRole minViewRole;
  final GroupRole minPostRole;
  final UserId createdBy;
  final int createdAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupChannel &&
          id == other.id &&
          name == other.name &&
          type == other.type &&
          minViewRole == other.minViewRole &&
          minPostRole == other.minPostRole &&
          createdBy == other.createdBy &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    type,
    minViewRole,
    minPostRole,
    createdBy,
    createdAt,
  );

  @override
  String toString() =>
      'GroupChannel(id=$id, type=$type, view=$minViewRole, post=$minPostRole)';
}

/// Состояние инвайта в проекции. Секрет ссылки здесь не хранится.
@immutable
class InviteRecord {
  const InviteRecord({
    required this.inviteId,
    required this.mode,
    required this.issuedBy,
    required this.uses,
    this.maxUses,
    this.expiresAt,
  });

  final String inviteId;
  final InviteMode mode;
  final UserId issuedBy;
  final int uses;
  final int? maxUses;
  final int? expiresAt;

  bool isExpiredAt(int timestamp) =>
      expiresAt != null && timestamp > expiresAt!;

  bool get isExhausted => maxUses != null && uses >= maxUses!;

  InviteRecord withUse() => InviteRecord(
    inviteId: inviteId,
    mode: mode,
    issuedBy: issuedBy,
    uses: uses + 1,
    maxUses: maxUses,
    expiresAt: expiresAt,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InviteRecord &&
          inviteId == other.inviteId &&
          mode == other.mode &&
          issuedBy == other.issuedBy &&
          uses == other.uses &&
          maxUses == other.maxUses &&
          expiresAt == other.expiresAt;

  @override
  int get hashCode =>
      Object.hash(inviteId, mode, issuedBy, uses, maxUses, expiresAt);

  @override
  String toString() =>
      'InviteRecord(id=$inviteId, mode=$mode, uses=$uses, maxUses=$maxUses)';
}

/// Последнее обработанное событие автора для проверки цепочки `prevId`.
@immutable
class AuthorCursor {
  const AuthorCursor({
    required this.id,
    required this.timestamp,
    required this.counter,
  });

  final EventId id;
  final int timestamp;
  final int counter;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuthorCursor &&
          id == other.id &&
          timestamp == other.timestamp &&
          counter == other.counter;

  @override
  int get hashCode => Object.hash(id, timestamp, counter);
}

/// Результат [GroupState.apply]. В отличие от `Result`, состояние доступно
/// и при семантическом отказе: цепочка автора уже сдвинута, чтобы следующие
/// события не терялись.
@immutable
class GroupApplyResult {
  const GroupApplyResult.ok(this.state) : error = null;

  const GroupApplyResult.err(this.state, this.error);

  final GroupState state;
  final GroupError? error;

  bool get isOk => error == null;
  bool get isErr => error != null;

  GroupState unwrap() {
    if (error != null) throw StateError('Called unwrap on an Err: $error');
    return state;
  }

  GroupError unwrapErr() {
    if (error == null) throw StateError('Called unwrapErr on an Ok: $state');
    return error!;
  }

  R when<R>({
    required R Function(GroupState) ok,
    required R Function(GroupError) err,
  }) => error == null ? ok(state) : err(error!);
}

/// Результат детерминированного replay журнала событий.
@immutable
class GroupReplay {
  const GroupReplay({
    required this.state,
    required this.processedEventIds,
    required this.errors,
    required this.epochEvents,
  });

  final GroupState state;

  /// События, прошедшие проверку цепочки и обработанные (включая
  /// семантические отказы и no-op).
  final Set<EventId> processedEventIds;

  /// Семантические ошибки по событиям из [processedEventIds].
  final Map<EventId, GroupError> errors;

  /// Событие, поднявшее каждую новую эпоху ключа.
  final Map<int, GroupEvent> epochEvents;

  GroupError? errorFor(EventId id) => errors[id];
}

/// Чистая проекция административных событий группы.
@immutable
class GroupState {
  const GroupState._({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.members,
    required this.channels,
    required this.invites,
    required this.pendingJoins,
    required this.keyEpoch,
    required this.createdAt,
    required this.updatedAt,
    required this.appliedEventIds,
    required this.genesisEventId,
    required this.cursors,
    required this.eventFingerprints,
  });

  factory GroupState({
    required GroupId id,
    required String name,
    required UserId ownerId,
    required Map<UserId, GroupRole> members,
    required Map<ChannelId, GroupChannel> channels,
    required Map<String, InviteRecord> invites,
    required Map<UserId, String> pendingJoins,
    required int keyEpoch,
    required int createdAt,
    required int updatedAt,
    required Set<EventId> appliedEventIds,
    EventId? genesisEventId,
    Map<UserId, AuthorCursor> cursors = const {},
    Map<EventId, String> eventFingerprints = const {},
  }) {
    if (appliedEventIds.isNotEmpty) {
      if (cursors.isEmpty || eventFingerprints.isEmpty) {
        throw ArgumentError(
          'Applied state requires cursors and eventFingerprints',
        );
      }
      final missing = appliedEventIds.difference(
        eventFingerprints.keys.toSet(),
      );
      if (missing.isNotEmpty) {
        throw ArgumentError(
          'Missing eventFingerprints for applied events: $missing',
        );
      }
      final cursorIds = cursors.values.map((cursor) => cursor.id).toSet();
      if (!appliedEventIds.containsAll(cursorIds)) {
        throw ArgumentError('Author cursor points to an unapplied event');
      }
    }
    return GroupState._(
      id: id,
      name: name,
      ownerId: ownerId,
      members: Map.unmodifiable(members),
      channels: Map.unmodifiable(channels),
      invites: Map.unmodifiable(invites),
      pendingJoins: Map.unmodifiable(pendingJoins),
      keyEpoch: keyEpoch,
      createdAt: createdAt,
      updatedAt: updatedAt,
      appliedEventIds: Set.unmodifiable(appliedEventIds),
      genesisEventId: genesisEventId,
      cursors: Map.unmodifiable(cursors),
      eventFingerprints: Map.unmodifiable(eventFingerprints),
    );
  }

  const GroupState.empty()
    : this._(
        id: const GroupId(''),
        name: '',
        ownerId: const UserId(''),
        members: const {},
        channels: const {},
        invites: const {},
        pendingJoins: const {},
        keyEpoch: 0,
        createdAt: 0,
        updatedAt: 0,
        appliedEventIds: const {},
        genesisEventId: null,
        cursors: const {},
        eventFingerprints: const {},
      );

  final GroupId id;
  final String name;
  final UserId ownerId;
  final Map<UserId, GroupRole> members;
  final Map<ChannelId, GroupChannel> channels;
  final Map<String, InviteRecord> invites;
  final Map<UserId, String> pendingJoins;
  final int keyEpoch;
  final int createdAt;
  final int updatedAt;
  final Set<EventId> appliedEventIds;
  final EventId? genesisEventId;

  /// Вершины цепочек `prevId` по авторам. Нужны для продолжения проверки
  /// цепочки после сериализации/восстановления состояния.
  final Map<UserId, AuthorCursor> cursors;

  /// Каноническое тело последнего обработанного события каждого id.
  final Map<EventId, String> eventFingerprints;

  bool get isInitialized => ownerId.value.isNotEmpty;

  /// Построение состояния из множества событий. Дубликаты по id разрешаются
  /// детерминированно, события применяются в порядке `(timestamp, counter, id)`
  /// после проверки цепочки `prevId` автора. `GroupCreated` применяется первым
  /// как корень истории.
  ///
  /// [expectedGroupId] и [genesisEventId] обязательны и фиксируют ожидаемое
  /// создание группы: поддельное или чужое `GroupCreated` не перехватит
  /// проекцию.
  /// [inviteProofVerifier] обязателен для `MemberJoined`; без него вход
  /// отклоняется (доказательство владения секретом инвайта).
  ///
  /// События должны приходить из `core_sync` с уже проверенными подписью и
  /// `id == SHA-256(canonical body)`. Выбор тела при совпадении id — только
  /// защита от дубликатов, а не замена проверке идентификатора.
  factory GroupState.fromEvents(
    Iterable<GroupEvent> events, {
    required GroupId expectedGroupId,
    required EventId genesisEventId,
    InviteProofVerifier? inviteProofVerifier,
  }) {
    return GroupState.replay(
      events,
      expectedGroupId: expectedGroupId,
      genesisEventId: genesisEventId,
      inviteProofVerifier: inviteProofVerifier,
    ).state;
  }

  /// Детерминированный replay журнала с диагностикой по событиям.
  static GroupReplay replay(
    Iterable<GroupEvent> events, {
    required GroupId expectedGroupId,
    required EventId genesisEventId,
    InviteProofVerifier? inviteProofVerifier,
  }) {
    final sameGroup = events
        .where((event) => event.groupId == expectedGroupId)
        .toList();
    final unique = _resolveDuplicates(sameGroup);
    final sorted = unique.values.toList()..sort(compareEvents);

    final errors = <EventId, GroupError>{};
    final processed = <EventId>{};
    final epochEvents = <int, GroupEvent>{};

    final creations =
        sameGroup
            .whereType<GroupCreated>()
            .where(
              (creation) =>
                  creation.groupId == expectedGroupId &&
                  creation.id == genesisEventId &&
                  creation.prevId == null,
            )
            .toList()
          ..sort((a, b) {
            final byBody = _compareBody(a, b);
            return byBody != 0 ? byBody : compareEvents(a, b);
          });

    var state = const GroupState.empty();
    GroupCreated? chosenCreation;

    for (final creation in creations) {
      final applied = state.apply(
        creation,
        expectedGroupId: expectedGroupId,
        genesisEventId: genesisEventId,
      );
      if (applied.isOk) {
        state = applied.state;
        chosenCreation = creation;
        processed.add(creation.id);
        break;
      }
      errors[creation.id] = applied.unwrapErr();
    }

    if (chosenCreation == null) {
      return GroupReplay(
        state: state,
        processedEventIds: processed,
        errors: errors,
        epochEvents: epochEvents,
      );
    }

    final rest = sorted
        .where(
          (event) =>
              event.groupId == chosenCreation!.groupId &&
              event is! GroupCreated,
        )
        .toList();
    final valid = _validChain(rest, chosenCreation);

    for (final event in valid) {
      final before = state;
      final applied = state.apply(
        event,
        inviteProofVerifier: inviteProofVerifier,
      );
      state = applied.state;
      processed.add(event.id);
      if (applied.isErr) errors[event.id] = applied.unwrapErr();
      if (state.keyEpoch > before.keyEpoch) {
        epochEvents[state.keyEpoch] = event;
      }
    }

    return GroupReplay(
      state: state,
      processedEventIds: processed,
      errors: errors,
      epochEvents: epochEvents,
    );
  }

  /// Детерминированный выбор тела при совпадении id.
  static Map<String, GroupEvent> _resolveDuplicates(
    Iterable<GroupEvent> events,
  ) {
    final grouped = <String, List<GroupEvent>>{};
    for (final event in events) {
      grouped.putIfAbsent(event.id.value, () => []).add(event);
    }
    return {
      for (final entry in grouped.entries)
        entry.key: entry.value.reduce(
          (a, b) => _compareBody(a, b) <= 0 ? a : b,
        ),
    };
  }

  /// Детерминированное сравнение тел событий с одинаковым id.
  @internal
  static int compareBodies(GroupEvent a, GroupEvent b) => _compareBody(a, b);

  static int _compareBody(GroupEvent a, GroupEvent b) =>
      _bodyKey(a).compareTo(_bodyKey(b));

  static String _bodyKey(GroupEvent event) {
    final map = event.toCanonicalMap();
    final keys = map.keys.toList()..sort();
    return jsonEncode({for (final key in keys) key: map[key]});
  }

  /// Оставляет только события, образующие корректную цепочку `prevId` автора:
  /// родитель существует, принадлежит тому же автору и имеет не больший
  /// HLC (не убывает). У автора должен быть ровно один корень (первое событие или потомок
  /// `GroupCreated`); автор с несколькими корнями отбрасывается целиком.
  /// При форке (несколько детей одного `prevId`) детерминированно выбирается
  /// меньший `(timestamp, counter, id)`.
  static List<GroupEvent> _validChain(
    List<GroupEvent> events,
    GroupCreated genesis,
  ) {
    final accepted = <String>{};
    final byAuthor = <UserId, List<GroupEvent>>{};
    for (final event in events) {
      byAuthor.putIfAbsent(event.authorId, () => []).add(event);
    }

    for (final entry in byAuthor.entries) {
      final author = entry.key;
      final chain = {for (final event in entry.value) event.id.value: event};
      final children = <String, List<GroupEvent>>{};
      final roots = <GroupEvent>[];

      for (final event in entry.value) {
        final prev = event.prevId;
        if (prev == null) {
          roots.add(event);
        } else if (chain.containsKey(prev.value)) {
          children.putIfAbsent(prev.value, () => []).add(event);
        } else if (author == genesis.authorId && prev == genesis.id) {
          children.putIfAbsent(prev.value, () => []).add(event);
        }
      }

      final genesisChildren =
          children[genesis.id.value] ?? const <GroupEvent>[];
      final hasGenesisChildren =
          author == genesis.authorId && genesisChildren.isNotEmpty;
      if (roots.length > 1 ||
          (roots.isNotEmpty && hasGenesisChildren) ||
          (roots.isEmpty && !hasGenesisChildren)) {
        // Несколько независимых корней автора: цепочка неоднозначна.
        // Форк детей genesis разрешается детерминированно ниже.
        continue;
      }

      final orderedChildren = <String, List<GroupEvent>>{
        for (final siblings in children.entries)
          siblings.key: (List<GroupEvent>.of(siblings.value)
            ..sort(compareEvents)),
      };

      GroupEvent? nextValidChild(GroupEvent node) =>
          orderedChildren[node.id.value]?.firstWhereOrNull(
            (child) => _compareHlc(child, node) >= 0,
          );

      void walk(GroupEvent node) {
        if (!accepted.add(node.id.value)) return;
        final child = nextValidChild(node);
        if (child != null) walk(child);
      }

      for (final root in roots) {
        walk(root);
      }
      final genesisChild = nextValidChild(genesis);
      if (genesisChild != null && author == genesis.authorId) {
        walk(genesisChild);
      }
    }

    return _topologicalOrder([
      for (final event in events)
        if (accepted.contains(event.id.value)) event,
    ], genesis);
  }

  /// Топологический порядок: ребёнок не раньше своего `prevId`, а среди
  /// доступных событий выбирается меньший `(timestamp, counter, id)`.
  /// Это закрывает случай равного HLC, когда id ребёнка меньше id родителя.
  static List<GroupEvent> _topologicalOrder(
    List<GroupEvent> events,
    GroupCreated genesis,
  ) {
    final roots = <GroupEvent>[];
    final children = <String, List<GroupEvent>>{};
    for (final event in events) {
      final prev = event.prevId;
      if (prev == null ||
          (event.authorId == genesis.authorId && prev == genesis.id)) {
        roots.add(event);
      } else {
        children.putIfAbsent(prev.value, () => []).add(event);
      }
    }

    final ready = HeapPriorityQueue<GroupEvent>(compareEvents)..addAll(roots);
    final ordered = <GroupEvent>[];
    while (ready.isNotEmpty) {
      final event = ready.removeFirst();
      ordered.add(event);
      final next = children[event.id.value];
      if (next != null) ready.addAll(next);
    }
    return ordered;
  }

  static int _compareHlc(GroupEvent a, GroupEvent b) {
    final byTimestamp = a.timestamp.compareTo(b.timestamp);
    if (byTimestamp != 0) return byTimestamp;
    return a.counter.compareTo(b.counter);
  }

  static int compareEvents(GroupEvent a, GroupEvent b) {
    final byTimestamp = a.timestamp.compareTo(b.timestamp);
    if (byTimestamp != 0) return byTimestamp;
    final byCounter = a.counter.compareTo(b.counter);
    if (byCounter != 0) return byCounter;
    return a.id.value.compareTo(b.id.value);
  }

  GroupRole? roleOf(UserId user) => members[user];

  bool canView(UserId user, ChannelId channelId) {
    final role = members[user];
    final channel = channels[channelId];
    if (role == null || channel == null) return false;
    return role.atLeast(channel.minViewRole);
  }

  bool canPost(UserId user, ChannelId channelId) {
    final role = members[user];
    final channel = channels[channelId];
    if (role == null || channel == null) return false;
    return role.atLeast(channel.minViewRole) &&
        role.atLeast(channel.minPostRole);
  }

  /// Применяет событие к состоянию. Чистая функция: не мутирует this.
  ///
  /// Дедупликация выполняется после проверки группы, чтобы событие с чужим
  /// `groupId` не маскировалось совпавшим id. Для `MemberJoined` требуется
  /// [inviteProofVerifier].
  GroupApplyResult apply(
    GroupEvent event, {
    InviteProofVerifier? inviteProofVerifier,
    GroupId? expectedGroupId,
    EventId? genesisEventId,
  }) {
    if (event is RoleSet && event.role == GroupRole.owner) {
      return GroupApplyResult.err(this, const OwnerRoleNotAssignable());
    }

    final invariants = event.validateInvariants();
    if (invariants.isErr) {
      return GroupApplyResult.err(this, InvalidEvent(invariants.unwrapErr()));
    }
    if (!isInitialized) {
      if (event is! GroupCreated) {
        return GroupApplyResult.err(this, const NotInitialized());
      }
      if (expectedGroupId == null ||
          genesisEventId == null ||
          event.groupId != expectedGroupId ||
          event.id != genesisEventId) {
        return GroupApplyResult.err(this, const GenesisMismatch());
      }
      final created = _applyCreated(event);
      if (created.isErr) {
        return GroupApplyResult.err(this, created.unwrapErr());
      }
      return GroupApplyResult.ok(created.unwrap()._advance(event));
    }
    if (event.groupId != id) {
      return GroupApplyResult.err(this, const GroupIdMismatch());
    }
    if (event is GroupCreated) {
      return GroupApplyResult.err(this, const AlreadyInitialized());
    }
    if (appliedEventIds.contains(event.id)) {
      final fingerprint = eventFingerprints[event.id];
      if (fingerprint != null && fingerprint != _bodyKey(event)) {
        return GroupApplyResult.err(this, const EventIdCollision());
      }
      return GroupApplyResult.ok(this);
    }
    final chain = _validateChain(event);
    if (chain.isErr) {
      return GroupApplyResult.err(this, chain.unwrapErr());
    }

    final result = switch (event) {
      InviteIssued e => _applyInviteIssued(e),
      MemberJoined e => _applyMemberJoined(e, inviteProofVerifier),
      MemberApproved e => _applyMemberApproved(e),
      MemberAdded e => _applyMemberAdded(e),
      MemberRemoved e => _applyMemberRemoved(e),
      RoleSet e => _applyRoleSet(e),
      ChannelCreated e => _applyChannelCreated(e),
      ChannelDeleted e => _applyChannelDeleted(e),
      GroupRenamed e => _applyGroupRenamed(e),
      OwnerTransferred e => _applyOwnerTransferred(e),
      KeyRotated e => _applyKeyRotated(e),
      GroupCreated e => _applyCreated(e),
    };
    if (result.isErr) {
      return GroupApplyResult.err(
        _advance(event)._withApplied({event.id}),
        result.unwrapErr(),
      );
    }
    return GroupApplyResult.ok(result.unwrap()._advance(event));
  }

  Result<void, GroupError> _validateChain(GroupEvent event) {
    final cursor = cursors[event.authorId];
    if (cursor == null) {
      return event.prevId == null
          ? const Ok(null)
          : const Err(EventChainBroken());
    }
    if (event.prevId != cursor.id) return const Err(EventChainBroken());
    if (event.timestamp < cursor.timestamp ||
        (event.timestamp == cursor.timestamp &&
            event.counter < cursor.counter)) {
      return const Err(EventChainBroken());
    }
    return const Ok(null);
  }

  /// Фиксирует принятое событие как вершину цепочки его автора.
  GroupState _advance(GroupEvent event) {
    return GroupState._(
      id: id,
      name: name,
      ownerId: ownerId,
      members: members,
      channels: channels,
      invites: invites,
      pendingJoins: pendingJoins,
      keyEpoch: keyEpoch,
      createdAt: createdAt,
      updatedAt: updatedAt,
      appliedEventIds: appliedEventIds,
      genesisEventId:
          genesisEventId ?? (event is GroupCreated ? event.id : null),
      cursors: {
        ...cursors,
        event.authorId: AuthorCursor(
          id: event.id,
          timestamp: event.timestamp,
          counter: event.counter,
        ),
      },
      eventFingerprints: {...eventFingerprints, event.id: _bodyKey(event)},
    );
  }

  Result<GroupState, GroupError> _applyCreated(GroupCreated event) {
    if (event.authorId != event.ownerId) {
      return const Err(Forbidden());
    }
    final members = <UserId, GroupRole>{
      for (final member in event.initialMembers) member: GroupRole.member,
      event.ownerId: GroupRole.owner,
    };
    return Ok(
      GroupState._(
        id: event.groupId,
        name: event.name,
        ownerId: event.ownerId,
        members: Map.unmodifiable(members),
        channels: const {},
        invites: const {},
        pendingJoins: const {},
        keyEpoch: 1,
        createdAt: event.timestamp,
        updatedAt: event.timestamp,
        appliedEventIds: {event.id},
        genesisEventId: event.id,
        cursors: {
          event.authorId: AuthorCursor(
            id: event.id,
            timestamp: event.timestamp,
            counter: event.counter,
          ),
        },
        eventFingerprints: {event.id: _bodyKey(event)},
      ),
    );
  }

  Result<GroupState, GroupError> _applyInviteIssued(InviteIssued event) {
    if (!_hasAtLeast(event, GroupRole.admin)) {
      return const Err(Forbidden());
    }
    if (invites.containsKey(event.inviteId)) {
      return const Err(InviteExists());
    }
    final record = InviteRecord(
      inviteId: event.inviteId,
      mode: event.mode,
      issuedBy: event.authorId,
      uses: 0,
      maxUses: event.maxUses,
      expiresAt: event.expiresAt,
    );
    return Ok(_next(event, invites: {...invites, event.inviteId: record}));
  }

  Result<GroupState, GroupError> _applyMemberJoined(
    MemberJoined event,
    InviteProofVerifier? verifier,
  ) {
    if (members.containsKey(event.authorId)) {
      return Ok(_withApplied({event.id}));
    }

    final invite = invites[event.inviteId];
    if (invite == null) return const Err(UnknownInvite());
    if (invite.isExpiredAt(event.timestamp)) {
      return const Err(InviteExpired());
    }
    if (invite.isExhausted) return const Err(InviteExhausted());

    if (event.inviteProof.isEmpty) {
      return const Err(InviteProofRequired());
    }
    final proofValid =
        verifier?.verify(
          groupId: id,
          inviteId: event.inviteId,
          userId: event.authorId,
          proof: event.inviteProof,
        ) ??
        false;
    if (!proofValid) return const Err(InvalidInviteProof());

    if (invite.mode == InviteMode.approval) {
      final pendingInvite = pendingJoins[event.authorId];
      if (pendingInvite == event.inviteId) {
        return Ok(_withApplied({event.id}));
      }
      if (pendingInvite != null) return const Err(JoinAlreadyPending());
      return Ok(
        _next(
          event,
          pendingJoins: {...pendingJoins, event.authorId: event.inviteId},
        ),
      );
    }

    return Ok(
      _next(
        event,
        members: {...members, event.authorId: GroupRole.member},
        invites: {...invites, event.inviteId: invite.withUse()},
        pendingJoins: _withoutPending(pendingJoins, event.authorId),
      ),
    );
  }

  Result<GroupState, GroupError> _applyMemberApproved(MemberApproved event) {
    if (!_hasAtLeast(event, GroupRole.admin)) {
      return const Err(Forbidden());
    }
    if (members.containsKey(event.userId)) {
      return Ok(_withApplied({event.id}));
    }
    if (pendingJoins[event.userId] != event.inviteId) {
      return const Err(JoinNotPending());
    }

    final invite = invites[event.inviteId];
    if (invite == null) return const Err(UnknownInvite());
    if (invite.isExpiredAt(event.timestamp)) {
      return const Err(InviteExpired());
    }
    if (invite.isExhausted) return const Err(InviteExhausted());

    return Ok(
      _next(
        event,
        members: {...members, event.userId: GroupRole.member},
        invites: {...invites, event.inviteId: invite.withUse()},
        pendingJoins: _withoutPending(pendingJoins, event.userId),
      ),
    );
  }

  Result<GroupState, GroupError> _applyMemberAdded(MemberAdded event) {
    if (!_hasAtLeast(event, GroupRole.admin)) {
      return const Err(Forbidden());
    }
    if (event.userId == ownerId || members.containsKey(event.userId)) {
      return Ok(_withApplied({event.id}));
    }
    return Ok(
      _next(event, members: {...members, event.userId: GroupRole.member}),
    );
  }

  Result<GroupState, GroupError> _applyMemberRemoved(MemberRemoved event) {
    if (!_hasAtLeast(event, GroupRole.moderator)) {
      return const Err(Forbidden());
    }
    if (event.userId == ownerId) {
      return const Err(OwnerImmutable());
    }
    if (event.userId == event.authorId) {
      return const Err(SelfTargetForbidden());
    }
    final targetRole = members[event.userId];
    if (targetRole == null) return const Err(TargetNotMember());

    final actorRole = members[event.authorId];
    if (actorRole == null) return const Err(NotAMember());
    if (!actorRole.atLeast(targetRole)) return const Err(Forbidden());

    final nextMembers = Map<UserId, GroupRole>.of(members)
      ..remove(event.userId);
    return Ok(
      _next(
        event,
        members: nextMembers,
        pendingJoins: _withoutPending(pendingJoins, event.userId),
        keyEpoch: keyEpoch + 1,
      ),
    );
  }

  Result<GroupState, GroupError> _applyRoleSet(RoleSet event) {
    if (!_hasAtLeast(event, GroupRole.admin)) {
      return const Err(Forbidden());
    }
    if (event.userId == ownerId) {
      return const Err(OwnerImmutable());
    }
    if (event.userId == event.authorId) {
      return const Err(SelfTargetForbidden());
    }
    final targetRole = members[event.userId];
    if (targetRole == null) return const Err(TargetNotMember());

    final actorRole = members[event.authorId];
    if (actorRole == null) return const Err(NotAMember());
    if (!actorRole.atLeast(targetRole)) return const Err(Forbidden());
    if (!actorRole.atLeast(event.role)) return const Err(Forbidden());

    return Ok(_next(event, members: {...members, event.userId: event.role}));
  }

  Result<GroupState, GroupError> _applyChannelCreated(ChannelCreated event) {
    if (!_hasAtLeast(event, GroupRole.admin)) {
      return const Err(Forbidden());
    }
    if (channels.containsKey(event.channelId)) {
      return const Err(ChannelExists());
    }
    final channel = GroupChannel(
      id: event.channelId,
      name: event.name,
      type: event.type,
      minViewRole: event.minViewRole,
      minPostRole: event.minPostRole,
      createdBy: event.authorId,
      createdAt: event.timestamp,
    );
    return Ok(_next(event, channels: {...channels, event.channelId: channel}));
  }

  Result<GroupState, GroupError> _applyChannelDeleted(ChannelDeleted event) {
    if (!_hasAtLeast(event, GroupRole.admin)) {
      return const Err(Forbidden());
    }
    if (!channels.containsKey(event.channelId)) {
      return const Err(UnknownChannel());
    }
    final nextChannels = Map<ChannelId, GroupChannel>.of(channels)
      ..remove(event.channelId);
    return Ok(_next(event, channels: nextChannels));
  }

  Result<GroupState, GroupError> _applyGroupRenamed(GroupRenamed event) {
    if (!_hasAtLeast(event, GroupRole.admin)) {
      return const Err(Forbidden());
    }
    return Ok(_next(event, name: event.name));
  }

  Result<GroupState, GroupError> _applyOwnerTransferred(
    OwnerTransferred event,
  ) {
    if (event.authorId != ownerId) return const Err(Forbidden());
    if (event.newOwnerId == ownerId) return Ok(_withApplied({event.id}));
    if (!members.containsKey(event.newOwnerId)) {
      return const Err(TargetNotMember());
    }

    final nextMembers = Map<UserId, GroupRole>.of(members)
      ..[ownerId] = GroupRole.admin
      ..[event.newOwnerId] = GroupRole.owner;

    return Ok(_next(event, ownerId: event.newOwnerId, members: nextMembers));
  }

  Result<GroupState, GroupError> _applyKeyRotated(KeyRotated event) {
    if (!_hasAtLeast(event, GroupRole.admin)) {
      return const Err(Forbidden());
    }
    if (event.newEpoch <= keyEpoch) {
      return const Err(InvalidKeyEpoch());
    }
    return Ok(_next(event, keyEpoch: event.newEpoch));
  }

  bool _hasAtLeast(GroupEvent event, GroupRole minimum) {
    final role = members[event.authorId];
    return role != null && role.atLeast(minimum);
  }

  /// Помечает событие обработанным без изменения содержимого состояния.
  GroupState _withApplied(
    Set<EventId> ids, {
    Map<EventId, String>? fingerprints,
  }) {
    return GroupState._(
      id: id,
      name: name,
      ownerId: ownerId,
      members: members,
      channels: channels,
      invites: invites,
      pendingJoins: pendingJoins,
      keyEpoch: keyEpoch,
      createdAt: createdAt,
      updatedAt: updatedAt,
      appliedEventIds: {...appliedEventIds, ...ids},
      genesisEventId: genesisEventId,
      cursors: cursors,
      eventFingerprints: {...eventFingerprints, ...?fingerprints},
    );
  }

  GroupState _next(
    GroupEvent event, {
    String? name,
    UserId? ownerId,
    Map<UserId, GroupRole>? members,
    Map<ChannelId, GroupChannel>? channels,
    Map<String, InviteRecord>? invites,
    Map<UserId, String>? pendingJoins,
    int? keyEpoch,
  }) {
    return GroupState._(
      id: id,
      name: name ?? this.name,
      ownerId: ownerId ?? this.ownerId,
      members: members ?? this.members,
      channels: channels ?? this.channels,
      invites: invites ?? this.invites,
      pendingJoins: pendingJoins ?? this.pendingJoins,
      keyEpoch: keyEpoch ?? this.keyEpoch,
      createdAt: createdAt,
      updatedAt: math.max(updatedAt, event.timestamp),
      appliedEventIds: {...appliedEventIds, event.id},
      genesisEventId: genesisEventId,
      cursors: cursors,
      eventFingerprints: {...eventFingerprints, event.id: _bodyKey(event)},
    );
  }

  static Map<UserId, String> _withoutPending(
    Map<UserId, String> source,
    UserId user,
  ) {
    if (!source.containsKey(user)) return source;
    return Map<UserId, String>.of(source)..remove(user);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupState &&
          id == other.id &&
          name == other.name &&
          ownerId == other.ownerId &&
          const MapEquality<UserId, GroupRole>().equals(
            members,
            other.members,
          ) &&
          const MapEquality<ChannelId, GroupChannel>().equals(
            channels,
            other.channels,
          ) &&
          const MapEquality<String, InviteRecord>().equals(
            invites,
            other.invites,
          ) &&
          const MapEquality<UserId, String>().equals(
            pendingJoins,
            other.pendingJoins,
          ) &&
          keyEpoch == other.keyEpoch &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt &&
          const SetEquality<EventId>().equals(
            appliedEventIds,
            other.appliedEventIds,
          ) &&
          genesisEventId == other.genesisEventId &&
          const MapEquality<UserId, AuthorCursor>().equals(
            cursors,
            other.cursors,
          ) &&
          const MapEquality<EventId, String>().equals(
            eventFingerprints,
            other.eventFingerprints,
          );

  @override
  int get hashCode => Object.hash(
    id,
    name,
    ownerId,
    const MapEquality<UserId, GroupRole>().hash(members),
    const MapEquality<ChannelId, GroupChannel>().hash(channels),
    const MapEquality<String, InviteRecord>().hash(invites),
    const MapEquality<UserId, String>().hash(pendingJoins),
    keyEpoch,
    createdAt,
    updatedAt,
    const SetEquality<EventId>().hash(appliedEventIds),
    genesisEventId,
    const MapEquality<UserId, AuthorCursor>().hash(cursors),
    const MapEquality<EventId, String>().hash(eventFingerprints),
  );

  @override
  String toString() =>
      'GroupState(id=$id, members=${members.length}, '
      'channels=${channels.length}, epoch=$keyEpoch)';
}
