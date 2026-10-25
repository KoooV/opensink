// ignore_for_file: prefer_initializing_formals
import 'dart:math';

import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';

import 'group_invite_proof_verifier.dart';

/// Ошибки выдачи и приёма инвайта. Секрет группы в них не попадает.
sealed class GroupInviteFailure {
  const GroupInviteFailure();

  @override
  String toString() => runtimeType.toString();
}

class InviteGroupNotReady extends GroupInviteFailure {
  const InviteGroupNotReady();

  @override
  String toString() => 'InviteGroupNotReady';
}

class InviteSecretUnavailable extends GroupInviteFailure {
  const InviteSecretUnavailable();

  @override
  String toString() => 'InviteSecretUnavailable';
}

class InvitePublishFailed extends GroupInviteFailure {
  const InvitePublishFailed(this.error);

  final GroupSyncError error;

  @override
  String toString() => 'InvitePublishFailed($error)';
}

class InviteJoinFailed extends GroupInviteFailure {
  const InviteJoinFailed(this.error);

  final GroupLifecycleError error;

  @override
  String toString() => 'InviteJoinFailed($error)';
}

/// Группа добавлена локально, но `MemberJoined` пока не опубликован:
/// история группы ещё не пришла из sync.
class InviteMembershipPending extends GroupInviteFailure {
  const InviteMembershipPending();

  @override
  String toString() => 'InviteMembershipPending';
}

class InviteMembershipFailed extends GroupInviteFailure {
  const InviteMembershipFailed(this.error);

  final GroupSyncError error;

  @override
  String toString() => 'InviteMembershipFailed($error)';
}

/// Результат входа: членство либо запрошено, либо ждёт историю группы.
class GroupJoinOutcome {
  const GroupJoinOutcome({
    required this.groupId,
    required this.membershipRequested,
    this.membershipIssue,
  });

  final GroupId groupId;
  final bool membershipRequested;
  final GroupInviteFailure? membershipIssue;

  bool get membershipPending => !membershipRequested;
}

/// Выдача и приём инвайт-ссылок поверх `GroupLifecycle`.
///
/// Ссылка содержит `GroupSecret` и выдаётся только после подписанного
/// `InviteIssued`. Повторный вход по той же ссылке идемпотентен.
class GroupInviteService {
  GroupInviteService({
    required GroupLifecycle lifecycle,
    required GroupSecretStore secretStore,
    required Signer signer,
    required UserId localUser,
    Random? random,
    int Function()? nowMs,
  }) : _lifecycle = lifecycle,
       _secretStore = secretStore,
       _signer = signer,
       _localUser = localUser,
       _random = random ?? Random.secure(),
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final GroupLifecycle _lifecycle;
  final GroupSecretStore _secretStore;
  final Signer _signer;
  final UserId _localUser;
  final Random _random;
  final int Function() _nowMs;

  /// Публикует `InviteIssued` и возвращает подписанную ссылку.
  Future<Result<InviteLink, GroupInviteFailure>> issue({
    required GroupId groupId,
    required GroupSyncBridge bridge,
    Duration ttl = const Duration(days: 7),
    int maxUses = 10,
    String relayHint = '',
  }) async {
    if (ttl <= Duration.zero || maxUses <= 0) {
      return const Err(InviteGroupNotReady());
    }
    if (bridge.state.id.value.isEmpty ||
        bridge.state.id != groupId ||
        bridge.state.ownerId.value.isEmpty) {
      return const Err(InviteGroupNotReady());
    }

    final loaded = await _secretStore.load(groupId);
    if (loaded.isErr) return const Err(InviteSecretUnavailable());
    final secret = loaded.unwrap();
    if (secret == null || secret.length != 32) {
      return const Err(InviteSecretUnavailable());
    }

    final inviteId = _newInviteId();
    final expiresAt = _nowMs() + ttl.inMilliseconds;
    final published = await bridge.publish(
      InviteIssued(
        id: const EventId(''),
        groupId: groupId,
        authorId: _localUser,
        timestamp: 0,
        prevId: bridge.nextPrevId,
        inviteId: inviteId,
        mode: InviteMode.open,
        maxUses: maxUses,
        expiresAt: expiresAt,
        relayHint: relayHint,
      ),
    );
    if (published.isErr) {
      return Err(InvitePublishFailed(published.unwrapErr()));
    }

    final link = await InviteLink.issue(
      signer: _signer,
      groupId: groupId,
      genesisEventId: bridge.genesisEventId,
      inviteId: inviteId,
      secret: encodeGroupSecretToken(secret),
      inviterId: _localUser,
      expiresAt: expiresAt,
      relayHint: relayHint,
    );
    return Ok(link);
  }

  /// Сохраняет доверенный корень и секрет, затем пытается опубликовать
  /// `MemberJoined`. Без локального genesis членство остаётся ожидающим.
  Future<Result<GroupJoinOutcome, GroupInviteFailure>> join(
    InviteLink link,
  ) async {
    final joined = await _lifecycle.joinFromInvite(link);
    if (joined.isErr) {
      return Err(InviteJoinFailed(joined.unwrapErr()));
    }
    final membershipIssue = await _announceMembership(link);
    return Ok(
      GroupJoinOutcome(
        groupId: link.groupId,
        membershipRequested: membershipIssue == null,
        membershipIssue: membershipIssue,
      ),
    );
  }

  Future<GroupInviteFailure?> _announceMembership(InviteLink link) async {
    final opened = await _lifecycle.open(link.groupId);
    if (opened.isErr) {
      return const InviteMembershipPending();
    }
    final bridge = opened.unwrap();
    try {
      if (bridge.state.memberIds.contains(_localUser)) return null;
      if (bridge.state.ownerId.value.isEmpty) {
        return const InviteMembershipPending();
      }

      final loaded = await _secretStore.load(link.groupId);
      if (loaded.isErr) return const InviteSecretUnavailable();
      final secret = loaded.unwrap();
      if (secret == null || secret.length != 32) {
        return const InviteSecretUnavailable();
      }

      final verifier = await GroupInviteProofVerifier.fromBytes(secret);
      final proof = verifier.computeProof(
        groupId: link.groupId,
        inviteId: link.inviteId,
        userId: _localUser,
      );
      final published = await bridge.publish(
        MemberJoined(
          id: const EventId(''),
          groupId: link.groupId,
          authorId: _localUser,
          timestamp: 0,
          prevId: bridge.nextPrevId,
          inviteId: link.inviteId,
          inviteProof: proof,
        ),
      );
      if (published.isErr) {
        return InviteMembershipFailed(published.unwrapErr());
      }
      return null;
    } finally {
      await bridge.close();
    }
  }

  String _newInviteId() {
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
