// ignore_for_file: prefer_initializing_formals
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

  /// Создаёт группу с новым случайным `groupId` и сохраняет корень.
  Future<Result<GroupId, GroupLifecycleError>> createGroup({
    required String name,
    Set<UserId>? initialMembers,
  }) async {
    final groupId = GroupId(_newGroupId());
    final pending = GroupMetadata(
      groupId: groupId,
      origin: GroupOrigin.created,
      createdAt: _nowMs(),
    );
    final saved = await _metadataStore.save(pending);
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
    final savedReady = await _metadataStore.save(ready);
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
  }

  /// Сохраняет доверенный корень из инвайта до приёма событий.
  Future<Result<void, GroupLifecycleError>> joinFromInvite(
    InviteLink link,
  ) async {
    final loaded = await _metadataStore.load(link.groupId);
    if (loaded.isErr) {
      return Err(GroupMetadataUnavailable(loaded.unwrapErr()));
    }
    final existing = loaded.unwrap();
    if (existing != null && existing.genesisEventId != link.genesisEventId) {
      return Err(
        GroupRootConflict(link.groupId, 'invite genesis differs from metadata'),
      );
    }

    final metadata =
        existing ??
        GroupMetadata(
          groupId: link.groupId,
          genesisEventId: link.genesisEventId,
          origin: GroupOrigin.invited,
          createdAt: _nowMs(),
        );
    if (!metadata.isReady) {
      return Err(
        GroupRootConflict(link.groupId, 'group metadata has no genesis'),
      );
    }
    final saved = await _metadataStore.save(metadata);
    if (saved.isErr) {
      return Err(GroupMetadataUnavailable(saved.unwrapErr()));
    }
    final activated = await _metadataStore.saveActiveGroup(link.groupId);
    if (activated.isErr) {
      return Err(GroupMetadataUnavailable(activated.unwrapErr()));
    }
    return const Ok(null);
  }

  /// Открывает группу по сохранённым метаданным.
  ///
  /// Для `created` отсутствие genesis — ошибка; для `invited` мост может
  /// ждать genesis из sync.
  Future<Result<GroupSyncBridge, GroupLifecycleError>> open(
    GroupId groupId,
  ) async {
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
    );
    final started = await bridge.start();
    if (started.isErr) {
      await bridge.close();
      return Err(GroupOpenFailed(started.unwrapErr()));
    }
    return Ok(bridge);
  }

  /// Восстанавливает незавершённые создания после рестарта.
  Future<Result<void, GroupLifecycleError>> recoverPendingGroups() async {
    final listed = await _metadataStore.list();
    if (listed.isErr) {
      return Err(GroupMetadataUnavailable(listed.unwrapErr()));
    }
    for (final metadata in listed.unwrap()) {
      if (metadata.isReady) continue;
      final recovered = await _recoverPending(metadata);
      if (recovered.isErr) return Err(recovered.unwrapErr());
    }
    return const Ok(null);
  }

  /// Загружает активную группу, очищая ссылку на удалённые метаданные.
  Future<Result<GroupId?, GroupLifecycleError>> loadActiveGroup() async {
    final recovered = await recoverPendingGroups();
    if (recovered.isErr) return Err(recovered.unwrapErr());

    final active = await _metadataStore.loadActiveGroup();
    if (active.isErr) {
      return Err(GroupMetadataUnavailable(active.unwrapErr()));
    }
    final groupId = active.unwrap();
    if (groupId == null) return const Ok(null);

    final metadata = await _metadataStore.load(groupId);
    if (metadata.isErr) {
      return Err(GroupMetadataUnavailable(metadata.unwrapErr()));
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
  Future<Result<void, GroupLifecycleError>> setActiveGroup(
    GroupId? groupId,
  ) async {
    if (groupId != null) {
      final metadata = await _metadataStore.load(groupId);
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
  }

  Future<Result<GroupMetadata, GroupLifecycleError>> _loadReadyMetadata(
    GroupId groupId,
  ) async {
    final loaded = await _metadataStore.load(groupId);
    if (loaded.isErr) {
      return Err(GroupMetadataUnavailable(loaded.unwrapErr()));
    }
    var metadata = loaded.unwrap();
    if (metadata == null) return Err(GroupNotFound(groupId));
    if (!metadata.isReady) {
      final recovered = await _recoverPending(metadata);
      if (recovered.isErr) return Err(recovered.unwrapErr());
      final reloaded = await _metadataStore.load(groupId);
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
    final candidates = events
        .where((event) => event.kind == SyncEventKind.groupCreated)
        .toList();
    if (candidates.isEmpty) {
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
    final saved = await _metadataStore.save(metadata.withGenesis(candidate.id));
    if (saved.isErr) {
      return Err(GroupMetadataUnavailable(saved.unwrapErr()));
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
