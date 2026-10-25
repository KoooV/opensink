// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:math';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';

import 'group_controller.dart';
import 'group_event_codec.dart';
import 'group_sync_bridge.dart';
import 'invite_link.dart';
import 'invite_proof.dart';
import 'key_distributor.dart';

/// Ошибки жизненного цикла группы.
sealed class GroupLifecycleError {
  const GroupLifecycleError();

  @override
  String toString() => runtimeType.toString();
}

class GroupNotFound extends GroupLifecycleError {
  const GroupNotFound(this.groupId);

  final GroupId groupId;

  @override
  String toString() => 'GroupNotFound(${groupId.value})';
}

class GroupMetadataUnavailable extends GroupLifecycleError {
  const GroupMetadataUnavailable(this.error);

  final GroupMetadataError error;

  @override
  String toString() => 'GroupMetadataUnavailable($error)';
}

class GroupCreateFailed extends GroupLifecycleError {
  const GroupCreateFailed(this.error);

  final GroupSyncError error;

  @override
  String toString() => 'GroupCreateFailed($error)';
}

class GroupOpenFailed extends GroupLifecycleError {
  const GroupOpenFailed(this.error);

  final GroupSyncError error;

  @override
  String toString() => 'GroupOpenFailed($error)';
}

class GroupRootConflict extends GroupLifecycleError {
  const GroupRootConflict(this.groupId, this.reason);

  final GroupId groupId;
  final String reason;

  @override
  String toString() => 'GroupRootConflict(${groupId.value}, $reason)';
}

/// Вход по инвайту недоступен: нет проверяющего доказательство владения
/// секретом группы (production-хранилище `GroupSecret` ещё не подключено).
class GroupInviteUnsupported extends GroupLifecycleError {
  const GroupInviteUnsupported();

  @override
  String toString() => 'GroupInviteUnsupported';
}

/// Инвайт-ссылка не прошла проверку подписи или срока.
class GroupInviteRejected extends GroupLifecycleError {
  const GroupInviteRejected(this.reason);

  final String reason;

  @override
  String toString() => 'GroupInviteRejected($reason)';
}

/// Создание, join и открытие группы по доверенным метаданным.
///
/// `groupId` и `genesisEventId` не выводятся из лога. Создание генерирует
/// `groupId` и сохраняет его до записи genesis; инвайт приносит оба значения.
class GroupLifecycle {
  GroupLifecycle({
    required SyncEngineImpl syncEngine,
    required GroupMetadataStore metadataStore,
    required GroupKeyDistributor distributor,
    InviteProofVerifier? inviteProofVerifier,
    GroupEventCodec codec = const GroupEventCodec(),
    int maxJournalEvents = 4096,
    Random? random,
    int Function()? nowMs,
  }) : _syncEngine = syncEngine,
       _metadataStore = metadataStore,
       _distributor = distributor,
       _inviteProofVerifier = inviteProofVerifier,
       _codec = codec,
       _maxJournalEvents = maxJournalEvents,
       _random = random ?? Random.secure(),
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SyncEngineImpl _syncEngine;
  final GroupMetadataStore _metadataStore;
  final GroupKeyDistributor _distributor;
  final InviteProofVerifier? _inviteProofVerifier;
  final GroupEventCodec _codec;
  final int _maxJournalEvents;
  final Random _random;
  final int Function() _nowMs;
  Future<void> _tail = Future<void>.value();

  /// Сериализует операции жизненного цикла: create/recover/join не должны
  /// перезаписывать или удалять метаданные друг друга.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<GroupMetadata> _signMetadata(GroupMetadata metadata) async {
    final signerId = _syncEngine.localAuthor;
    final signature = await _syncEngine.signer.sign(
      metadata.signingBytes(signerId),
    );
    return metadata.withAuth(signerId: signerId, signature: signature);
  }

  Future<Result<void, GroupMetadataError>> _saveMetadata(
    GroupMetadata metadata,
  ) async {
    final signed = await _signMetadata(metadata);
    return _metadataStore.save(signed);
  }

  Future<Result<GroupMetadata, GroupMetadataError>> _verifyMetadata(
    GroupMetadata metadata,
  ) async {
    final signerId = metadata.signerId;
    final signature = metadata.signature;
    if (signerId == null || signature == null) {
      return const Err(CorruptedGroupMetadata('metadata is not signed'));
    }
    if (signerId != _syncEngine.localAuthor) {
      return const Err(CorruptedGroupMetadata('metadata signer mismatch'));
    }
    final key = hexDecode(signerId.value);
    if (key == null || key.length != 32) {
      return const Err(CorruptedGroupMetadata('metadata signer key invalid'));
    }
    final valid = await _syncEngine.signer.verify(
      metadata.signingBytes(signerId),
      signature,
      PeerId(key),
    );
    if (!valid) {
      return const Err(CorruptedGroupMetadata('metadata signature invalid'));
    }
    return Ok(metadata);
  }

  Future<Result<GroupMetadata?, GroupMetadataError>> _loadVerifiedMetadata(
    GroupId groupId,
  ) async {
    final loaded = await _metadataStore.load(groupId);
    if (loaded.isErr) return Err(loaded.unwrapErr());
    final metadata = loaded.unwrap();
    if (metadata == null) return const Ok(null);
    final verified = await _verifyMetadata(metadata);
    if (verified.isErr) return Err(verified.unwrapErr());
    return Ok(verified.unwrap());
  }

  Future<GroupLifecycleError?> _verifyInvite(InviteLink link) async {
    if (link.groupId.value.isEmpty) {
      return const GroupInviteRejected('empty groupId');
    }
    final genesis = hexDecode(link.genesisEventId.value);
    if (genesis == null || genesis.length != 32) {
      return const GroupInviteRejected('genesis is not 64-hex');
    }
    if (link.expiresAt <= _nowMs()) {
      return const GroupInviteRejected('invite expired');
    }
    final valid = await link.verifySignature(_syncEngine.signer);
    if (!valid) {
      return const GroupInviteRejected('invalid inviter signature');
    }
    return null;
  }

  /// Создаёт группу с новым случайным `groupId` и сохраняет корень.
  Future<Result<GroupId, GroupLifecycleError>> createGroup({
    required String name,
    Set<UserId>? initialMembers,
  }) {
    return _serialized(() async {
      final groupId = GroupId(_newGroupId());
      final pending = GroupMetadata(
        groupId: groupId,
        origin: GroupOrigin.created,
        createdAt: _nowMs(),
      );
      final saved = await _saveMetadata(pending);
      if (saved.isErr) {
        return Err(GroupMetadataUnavailable(saved.unwrapErr()));
      }

      final created = await GroupSyncBridge.create(
        syncEngine: _syncEngine,
        groupId: groupId,
        name: name,
        initialMembers: initialMembers,
        distributor: _distributor,
        inviteProofVerifier: _inviteProofVerifier,
        maxJournalEvents: _maxJournalEvents,
        codec: _codec,
      );
      if (created.isErr) {
        await _recoverPending(pending);
        return Err(GroupCreateFailed(created.unwrapErr()));
      }

      final bridge = created.unwrap();
      final ready = pending.withGenesis(bridge.genesisEventId);
      final savedReady = await _saveMetadata(ready);
      if (savedReady.isErr) {
        await bridge.close();
        return Err(GroupMetadataUnavailable(savedReady.unwrapErr()));
      }
      final activated = await _metadataStore.saveActiveGroup(groupId);
      await bridge.close();
      if (activated.isErr) {
        return Err(GroupMetadataUnavailable(activated.unwrapErr()));
      }
      return Ok(groupId);
    });
  }

  /// Сохраняет доверенный корень из инвайта до приёма событий.
  Future<Result<void, GroupLifecycleError>> joinFromInvite(InviteLink link) {
    if (_inviteProofVerifier == null) {
      return Future<Result<void, GroupLifecycleError>>.value(
        const Err(GroupInviteUnsupported()),
      );
    }
    return _serialized(() async {
      final inviteError = await _verifyInvite(link);
      if (inviteError != null) return Err(inviteError);

      final loaded = await _loadVerifiedMetadata(link.groupId);
      if (loaded.isErr) {
        return Err(GroupMetadataUnavailable(loaded.unwrapErr()));
      }
      final existing = loaded.unwrap();
      if (existing != null && existing.genesisEventId != link.genesisEventId) {
        return Err(
          GroupRootConflict(
            link.groupId,
            'invite genesis differs from metadata',
          ),
        );
      }

      final metadata =
          existing ??
          GroupMetadata(
            groupId: link.groupId,
            genesisEventId: link.genesisEventId,
            origin: GroupOrigin.invited,
            createdAt: _nowMs(),
            inviterId: link.inviterId,
          );
      if (!metadata.isReady) {
        return Err(
          GroupRootConflict(link.groupId, 'group metadata has no genesis'),
        );
      }
      final saved = await _saveMetadata(metadata);
      if (saved.isErr) {
        return Err(GroupMetadataUnavailable(saved.unwrapErr()));
      }
      final activated = await _metadataStore.saveActiveGroup(link.groupId);
      if (activated.isErr) {
        return Err(GroupMetadataUnavailable(activated.unwrapErr()));
      }
      return const Ok(null);
    });
  }

  /// Открывает группу по сохранённым метаданным.
  ///
  /// Для `created` отсутствие genesis — ошибка; для `invited` мост может
  /// ждать genesis из sync.
  Future<Result<GroupSyncBridge, GroupLifecycleError>> open(GroupId groupId) {
    return _serialized(() async {
      final metadataResult = await _loadReadyMetadata(groupId);
      if (metadataResult.isErr) return Err(metadataResult.unwrapErr());
      final metadata = metadataResult.unwrap();

      final controller = GroupController(
        distributor: _distributor,
        expectedGroupId: groupId,
        genesisEventId: metadata.genesisEventId!,
        inviteProofVerifier: _inviteProofVerifier,
        maxJournalEvents: _maxJournalEvents,
      );
      final bridge = GroupSyncBridge(
        syncEngine: _syncEngine,
        controller: controller,
        groupId: groupId,
        codec: _codec,
        allowMissingGenesis: metadata.origin == GroupOrigin.invited,
        requireLocalAuthor: metadata.origin == GroupOrigin.created,
      );
      final started = await bridge.start();
      if (started.isErr) {
        await bridge.close();
        return Err(GroupOpenFailed(started.unwrapErr()));
      }
      return Ok(bridge);
    });
  }

  /// Восстанавливает незавершённые создания после рестарта.
  Future<Result<void, GroupLifecycleError>> recoverPendingGroups() {
    return _serialized(_recoverPendingGroups);
  }

  Future<Result<void, GroupLifecycleError>> _recoverPendingGroups() async {
    final listed = await _metadataStore.list();
    if (listed.isErr) {
      return Err(GroupMetadataUnavailable(listed.unwrapErr()));
    }
    GroupLifecycleError? firstError;
    for (final metadata in listed.unwrap()) {
      final verified = await _verifyMetadata(metadata);
      if (verified.isErr) {
        await _metadataStore.delete(metadata.groupId);
        continue;
      }
      final valid = verified.unwrap();
      if (valid.isReady) continue;
      final recovered = await _recoverPending(valid);
      if (recovered.isErr) {
        firstError ??= recovered.unwrapErr();
      }
    }
    final error = firstError;
    return error == null ? const Ok(null) : Err(error);
  }

  /// Загружает активную группу, очищая ссылку на удалённые метаданные.
  Future<Result<GroupId?, GroupLifecycleError>> loadActiveGroup() {
    return _serialized(_loadActiveGroup);
  }

  Future<Result<GroupId?, GroupLifecycleError>> _loadActiveGroup() async {
    await _recoverPendingGroups();

    final active = await _metadataStore.loadActiveGroup();
    if (active.isErr) {
      return Err(GroupMetadataUnavailable(active.unwrapErr()));
    }
    final groupId = active.unwrap();
    if (groupId == null) return const Ok(null);

    final metadata = await _loadVerifiedMetadata(groupId);
    if (metadata.isErr) {
      final error = metadata.unwrapErr();
      if (error is CorruptedGroupMetadata) {
        await _metadataStore.delete(groupId);
        final cleared = await _metadataStore.saveActiveGroup(null);
        if (cleared.isErr) {
          return Err(GroupMetadataUnavailable(cleared.unwrapErr()));
        }
        return const Ok(null);
      }
      return Err(GroupMetadataUnavailable(error));
    }
    if (metadata.unwrap() == null) {
      final cleared = await _metadataStore.saveActiveGroup(null);
      if (cleared.isErr) {
        return Err(GroupMetadataUnavailable(cleared.unwrapErr()));
      }
      return const Ok(null);
    }
    return Ok(groupId);
  }

  /// Сохраняет активную группу; `null` очищает выбор.
  Future<Result<void, GroupLifecycleError>> setActiveGroup(GroupId? groupId) {
    return _serialized(() async {
      if (groupId != null) {
        final metadata = await _loadVerifiedMetadata(groupId);
        if (metadata.isErr) {
          return Err(GroupMetadataUnavailable(metadata.unwrapErr()));
        }
        if (metadata.unwrap() == null) return Err(GroupNotFound(groupId));
      }
      final saved = await _metadataStore.saveActiveGroup(groupId);
      if (saved.isErr) {
        return Err(GroupMetadataUnavailable(saved.unwrapErr()));
      }
      return const Ok(null);
    });
  }

  /// Удаляет метаданные группы и очищает активный выбор.
  ///
  /// Нужен для ремонта после отклонённого инвайта или конфликта корня.
  Future<Result<void, GroupLifecycleError>> deleteGroup(GroupId groupId) {
    return _serialized(() async {
      final active = await _metadataStore.loadActiveGroup();
      if (active.isErr) {
        return Err(GroupMetadataUnavailable(active.unwrapErr()));
      }
      final deleted = await _metadataStore.delete(groupId);
      if (deleted.isErr) {
        return Err(GroupMetadataUnavailable(deleted.unwrapErr()));
      }
      if (active.unwrap() == groupId) {
        final cleared = await _metadataStore.saveActiveGroup(null);
        if (cleared.isErr) {
          return Err(GroupMetadataUnavailable(cleared.unwrapErr()));
        }
      }
      return const Ok(null);
    });
  }

  Future<Result<GroupMetadata, GroupLifecycleError>> _loadReadyMetadata(
    GroupId groupId,
  ) async {
    final loaded = await _loadVerifiedMetadata(groupId);
    if (loaded.isErr) {
      return Err(GroupMetadataUnavailable(loaded.unwrapErr()));
    }
    var metadata = loaded.unwrap();
    if (metadata == null) return Err(GroupNotFound(groupId));
    if (!metadata.isReady) {
      final recovered = await _recoverPending(metadata);
      if (recovered.isErr) return Err(recovered.unwrapErr());
      final reloaded = await _loadVerifiedMetadata(groupId);
      if (reloaded.isErr) {
        return Err(GroupMetadataUnavailable(reloaded.unwrapErr()));
      }
      metadata = reloaded.unwrap();
    }
    if (metadata == null || !metadata.isReady) {
      return Err(GroupNotFound(groupId));
    }
    return Ok(metadata);
  }

  Future<Result<void, GroupLifecycleError>> _recoverPending(
    GroupMetadata metadata,
  ) async {
    if (metadata.isReady) return const Ok(null);
    final events = await _syncEngine.allEvents(metadata.groupId);
    final roots = events
        .where((event) => event.kind == SyncEventKind.groupCreated)
        .toList();
    final candidates = roots
        .where((event) => event.authorId == _syncEngine.localAuthor)
        .toList();
    if (candidates.isEmpty) {
      if (roots.isNotEmpty) {
        return Err(
          GroupRootConflict(
            metadata.groupId,
            'foreign genesis without local root',
          ),
        );
      }
      final deleted = await _metadataStore.delete(metadata.groupId);
      if (deleted.isErr) {
        return Err(GroupMetadataUnavailable(deleted.unwrapErr()));
      }
      return const Ok(null);
    }
    if (candidates.length > 1) {
      return Err(
        GroupRootConflict(
          metadata.groupId,
          'multiple local genesis candidates',
        ),
      );
    }
    final candidate = candidates.single;
    if (!await _isValidLocalGenesis(candidate, metadata.groupId)) {
      return Err(
        GroupRootConflict(metadata.groupId, 'local genesis is invalid'),
      );
    }
    final saved = await _saveMetadata(metadata.withGenesis(candidate.id));
    if (saved.isErr) {
      return Err(GroupMetadataUnavailable(saved.unwrapErr()));
    }
    return _restoreInitialMembers(candidate, events);
  }

  /// Досоздаёт отсутствующие `MemberAdded` для `initialMembers` genesis.
  ///
  /// `core_sync` не разбирает `initialMembers`, поэтому после падения между
  /// genesis и MemberAdded начальные участники не смогли бы публиковать в
  /// группе. Операция идемпотентна: уже существующие добавления пропускаются.
  Future<Result<void, GroupLifecycleError>> _restoreInitialMembers(
    SyncEvent genesisEvent,
    List<SyncEvent> events,
  ) async {
    final decoded = _codec.decode(genesisEvent);
    if (decoded.isErr) {
      return Err(GroupCreateFailed(decoded.unwrapErr()));
    }
    final genesis = decoded.unwrap();
    if (genesis is! GroupCreated) {
      return const Err(
        GroupCreateFailed(MalformedGroupEvent('genesis is not GroupCreated')),
      );
    }
    final added = {
      for (final event in events)
        if (event.kind == SyncEventKind.memberAdded && event.targetId != null)
          event.targetId!,
    };
    for (final member in genesis.initialMembers) {
      if (member == genesis.ownerId || member.value.isEmpty) continue;
      if (!added.add(member.value)) continue;
      final payload = _codec.encode(
        MemberAdded(
          id: const EventId(''),
          groupId: genesis.groupId,
          authorId: _syncEngine.localAuthor,
          timestamp: 0,
          userId: member,
        ),
      );
      if (payload.isErr) {
        return Err(GroupCreateFailed(payload.unwrapErr()));
      }
      final created = await _syncEngine.createEvent(
        groupId: genesis.groupId,
        kind: SyncEventKind.memberAdded,
        targetId: member.value,
        payload: payload.unwrap(),
      );
      if (created.isErr) {
        return Err(GroupCreateFailed(SyncEngineFailure(created.unwrapErr())));
      }
    }
    return const Ok(null);
  }

  Future<bool> _isValidLocalGenesis(SyncEvent event, GroupId groupId) async {
    if (event.groupId != groupId) return false;
    if (event.id.value != event.computeId()) return false;
    final decoded = _codec.decode(event);
    if (decoded.isErr) return false;
    final genesis = decoded.unwrap();
    if (genesis is! GroupCreated) return false;
    if (genesis.groupId != groupId) return false;
    if (genesis.authorId != _syncEngine.localAuthor) return false;
    if (genesis.authorId != genesis.ownerId) return false;
    if (!genesis.initialMembers.contains(genesis.ownerId)) return false;
    if (genesis.validateInvariants().isErr) return false;
    if (event.signature.isEmpty) return false;
    final authorBytes = hexDecode(event.authorId.value);
    if (authorBytes == null || authorBytes.length != 32) return false;
    return _syncEngine.signer.verify(
      event.signedBytes(),
      event.signature,
      PeerId(authorBytes),
    );
  }

  String _newGroupId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
