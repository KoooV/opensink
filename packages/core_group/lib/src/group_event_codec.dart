import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_protocol/core_protocol.dart' as proto;
import 'package:core_sync/core_sync.dart' show SyncEvent, SyncEventKind;

import 'group_error.dart';

/// Ошибки моста между доменными групповыми событиями и `core_sync`.
sealed class GroupSyncError {
  const GroupSyncError();
}

class UnsupportedGroupEvent extends GroupSyncError {
  const UnsupportedGroupEvent(this.kind);

  final SyncEventKind kind;

  @override
  String toString() => 'UnsupportedGroupEvent($kind)';
}

class MalformedGroupEvent extends GroupSyncError {
  const MalformedGroupEvent(this.reason);

  final String reason;

  @override
  String toString() => 'MalformedGroupEvent($reason)';
}

class GroupEventKindMismatch extends GroupSyncError {
  const GroupEventKindMismatch(this.expected, this.actual);

  final SyncEventKind expected;
  final int actual;

  @override
  String toString() =>
      'GroupEventKindMismatch(expected=$expected, actual=$actual)';
}

class GroupAuthorMismatch extends GroupSyncError {
  const GroupAuthorMismatch(this.expected, this.actual);

  final UserId expected;
  final UserId actual;

  @override
  String toString() =>
      'GroupAuthorMismatch(expected=${expected.value}, actual=${actual.value})';
}

class GroupIdMismatchError extends GroupSyncError {
  const GroupIdMismatchError(this.expected, this.actual);

  final GroupId expected;
  final GroupId actual;

  @override
  String toString() =>
      'GroupIdMismatchError(expected=${expected.value}, actual=${actual.value})';
}

class SyncEngineFailure extends GroupSyncError {
  const SyncEngineFailure(this.error);

  final Object error;

  @override
  String toString() => 'SyncEngineFailure($error)';
}

class ControllerFailure extends GroupSyncError {
  const ControllerFailure(this.error);

  final GroupError error;

  @override
  String toString() => 'ControllerFailure($error)';
}

/// Канонический кодек групповых событий в payload `SyncEvent`.
///
/// Payload — плоский `core_protocol.GroupEvent`. Поля `id/groupId/authorId/
/// timestamp/signature` не заполняются и восстанавливаются из `SyncEvent`.
/// `domainPrevId` хранит цепочку только административных событий автора.
class GroupEventCodec {
  const GroupEventCodec();

  bool isGroupEventKind(SyncEventKind kind) => switch (kind) {
    SyncEventKind.groupCreated ||
    SyncEventKind.memberAdded ||
    SyncEventKind.memberRemoved ||
    SyncEventKind.channelCreated ||
    SyncEventKind.channelDeleted ||
    SyncEventKind.groupRenamed ||
    SyncEventKind.ownerTransferred ||
    SyncEventKind.inviteIssued ||
    SyncEventKind.memberJoined ||
    SyncEventKind.memberApproved ||
    SyncEventKind.roleSet ||
    SyncEventKind.keyRotated => true,
    _ => false,
  };

  SyncEventKind kindOf(GroupEvent event) => switch (event) {
    GroupCreated() => SyncEventKind.groupCreated,
    MemberAdded() => SyncEventKind.memberAdded,
    MemberRemoved() => SyncEventKind.memberRemoved,
    ChannelCreated() => SyncEventKind.channelCreated,
    ChannelDeleted() => SyncEventKind.channelDeleted,
    GroupRenamed() => SyncEventKind.groupRenamed,
    OwnerTransferred() => SyncEventKind.ownerTransferred,
    InviteIssued() => SyncEventKind.inviteIssued,
    MemberJoined() => SyncEventKind.memberJoined,
    MemberApproved() => SyncEventKind.memberApproved,
    RoleSet() => SyncEventKind.roleSet,
    KeyRotated() => SyncEventKind.keyRotated,
  };

  String? targetIdOf(GroupEvent event) => switch (event) {
    MemberAdded e => e.userId.value,
    MemberRemoved e => e.userId.value,
    ChannelCreated e => e.channelId.value,
    ChannelDeleted e => e.channelId.value,
    OwnerTransferred e => e.newOwnerId.value,
    InviteIssued e => e.inviteId,
    MemberJoined e => e.inviteId,
    MemberApproved e => e.userId.value,
    RoleSet e => e.userId.value,
    GroupCreated() || GroupRenamed() || KeyRotated() => null,
  };

  ChannelId? channelIdOf(GroupEvent event) => switch (event) {
    ChannelCreated e => e.channelId,
    ChannelDeleted e => e.channelId,
    _ => null,
  };

  Result<Uint8List, GroupSyncError> encode(GroupEvent event) {
    final protoEvent = _toProto(event);
    if (protoEvent.isErr) return Err(protoEvent.unwrapErr());
    return Ok(protoEvent.unwrap().toBytes());
  }

  Result<GroupEvent, GroupSyncError> decode(SyncEvent event) {
    if (!isGroupEventKind(event.kind)) {
      return Err(UnsupportedGroupEvent(event.kind));
    }
    final decoded = _decodePayload(event);
    if (decoded.isErr) return Err(decoded.unwrapErr());
    final payload = decoded.unwrap();
    if (payload.eventType != event.kind.code) {
      return Err(GroupEventKindMismatch(event.kind, payload.eventType));
    }
    return _toDomain(event, payload);
  }

  Result<proto.GroupEvent, GroupSyncError> _decodePayload(SyncEvent event) {
    try {
      return Ok(proto.GroupEvent.fromBytes(event.payload));
    } catch (error) {
      return Err(MalformedGroupEvent(error.toString()));
    }
  }

  Result<proto.GroupEvent, GroupSyncError> _toProto(GroupEvent event) {
    final kind = kindOf(event);
    final base = proto.GroupEvent(
      id: event.id.value,
      groupId: event.groupId.value,
      authorId: event.authorId.value,
      timestamp: event.timestamp,
      eventType: kind.code,
    );
    final prev = event.prevId?.value ?? '';
    final encoded = switch (event) {
      GroupCreated e => base.copyWith(
        name: e.name,
        ownerId: e.ownerId.value,
        initialMembers: e.initialMembers.map((member) => member.value).toList()
          ..sort(),
        domainPrevId: prev,
      ),
      MemberAdded e => base.copyWith(
        userId: e.userId.value,
        domainPrevId: prev,
      ),
      MemberRemoved e => base.copyWith(
        userId: e.userId.value,
        domainPrevId: prev,
      ),
      ChannelCreated e => base.copyWith(
        channelId: e.channelId.value,
        name: e.name,
        channelType: e.type,
        minViewRole: e.minViewRole.name,
        minPostRole: e.minPostRole.name,
        domainPrevId: prev,
      ),
      ChannelDeleted e => base.copyWith(
        channelId: e.channelId.value,
        domainPrevId: prev,
      ),
      GroupRenamed e => base.copyWith(name: e.name, domainPrevId: prev),
      OwnerTransferred e => base.copyWith(
        newOwnerId: e.newOwnerId.value,
        domainPrevId: prev,
      ),
      InviteIssued e => base.copyWith(
        inviteId: e.inviteId,
        inviteMode: e.mode.name,
        maxUses: e.maxUses ?? 0,
        expiresAt: e.expiresAt ?? 0,
        relayHint: e.relayHint,
        domainPrevId: prev,
      ),
      MemberJoined e => base.copyWith(
        inviteId: e.inviteId,
        inviteProof: e.inviteProof,
        domainPrevId: prev,
      ),
      MemberApproved e => base.copyWith(
        userId: e.userId.value,
        inviteId: e.inviteId,
        domainPrevId: prev,
      ),
      RoleSet e => base.copyWith(
        userId: e.userId.value,
        role: e.role.name,
        domainPrevId: prev,
      ),
      KeyRotated e => base.copyWith(
        newEpoch: e.newEpoch,
        domainPrevId: prev,
      ),
    };
    return Ok(encoded);
  }

  Result<GroupEvent, GroupSyncError> _toDomain(
    SyncEvent event,
    proto.GroupEvent payload,
  ) {
    final id = event.id;
    final groupId = event.groupId;
    final authorId = event.authorId;
    final timestamp = event.hlc.physicalMs;
    final counter = event.hlc.counter;
    final prevId = payload.domainPrevId.isEmpty
        ? null
        : EventId(payload.domainPrevId);

    final role = _parseRole(payload.role);
    if (role.isErr) return Err(role.unwrapErr());
    final minViewRole = _parseRole(payload.minViewRole);
    if (minViewRole.isErr) return Err(minViewRole.unwrapErr());
    final minPostRole = _parseRole(payload.minPostRole);
    if (minPostRole.isErr) return Err(minPostRole.unwrapErr());
    final mode = _parseInviteMode(payload.inviteMode);
    if (mode.isErr) return Err(mode.unwrapErr());

    final userId = UserId(
      payload.userId.isEmpty ? (event.targetId ?? '') : payload.userId,
    );
    final channelId = ChannelId(
      payload.channelId.isEmpty
          ? (event.channelId?.value ?? event.targetId ?? '')
          : payload.channelId,
    );

    GroupEvent domain;
    switch (event.kind) {
      case SyncEventKind.groupCreated:
        domain = GroupCreated(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          name: payload.name,
          ownerId: UserId(
            payload.ownerId.isEmpty ? authorId.value : payload.ownerId,
          ),
          initialMembers: payload.initialMembers.map(UserId.new).toSet(),
        );
        break;
      case SyncEventKind.memberAdded:
        domain = MemberAdded(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          userId: userId,
        );
        break;
      case SyncEventKind.memberRemoved:
        domain = MemberRemoved(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          userId: userId,
        );
        break;
      case SyncEventKind.channelCreated:
        domain = ChannelCreated(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          channelId: channelId,
          name: payload.name,
          type: payload.channelType,
          minViewRole: minViewRole.unwrap(),
          minPostRole: minPostRole.unwrap(),
        );
        break;
      case SyncEventKind.channelDeleted:
        domain = ChannelDeleted(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          channelId: channelId,
        );
        break;
      case SyncEventKind.groupRenamed:
        domain = GroupRenamed(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          name: payload.name,
        );
        break;
      case SyncEventKind.ownerTransferred:
        domain = OwnerTransferred(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          newOwnerId: UserId(
            payload.newOwnerId.isEmpty
                ? (event.targetId ?? '')
                : payload.newOwnerId,
          ),
        );
        break;
      case SyncEventKind.inviteIssued:
        domain = InviteIssued(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          inviteId: payload.inviteId.isEmpty
              ? (event.targetId ?? '')
              : payload.inviteId,
          mode: mode.unwrap(),
          maxUses: payload.maxUses == 0 ? null : payload.maxUses,
          expiresAt: payload.expiresAt == 0 ? null : payload.expiresAt,
          relayHint: payload.relayHint,
        );
        break;
      case SyncEventKind.memberJoined:
        domain = MemberJoined(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          inviteId: payload.inviteId.isEmpty
              ? (event.targetId ?? '')
              : payload.inviteId,
          inviteProof: payload.inviteProof,
        );
        break;
      case SyncEventKind.memberApproved:
        domain = MemberApproved(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          userId: userId,
          inviteId: payload.inviteId.isEmpty
              ? (event.targetId ?? '')
              : payload.inviteId,
        );
        break;
      case SyncEventKind.roleSet:
        domain = RoleSet(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          userId: userId,
          role: role.unwrap(),
        );
        break;
      case SyncEventKind.keyRotated:
        domain = KeyRotated(
          id: id,
          groupId: groupId,
          authorId: authorId,
          timestamp: timestamp,
          counter: counter,
          prevId: prevId,
          newEpoch: payload.newEpoch,
        );
        break;
      default:
        return Err(UnsupportedGroupEvent(event.kind));
    }

    if (domain is ChannelCreated && domain.channelId.value.isEmpty) {
      return const Err(MalformedGroupEvent('empty channel id'));
    }
    if (domain is ChannelDeleted && domain.channelId.value.isEmpty) {
      return const Err(MalformedGroupEvent('empty channel id'));
    }
    return Ok(domain);
  }

  Result<GroupRole, GroupSyncError> _parseRole(String value) {
    if (value.isEmpty) return const Ok(GroupRole.member);
    for (final role in GroupRole.values) {
      if (role.name == value) return Ok(role);
    }
    return Err(MalformedGroupEvent('unknown role $value'));
  }

  Result<InviteMode, GroupSyncError> _parseInviteMode(String value) {
    if (value.isEmpty || value == InviteMode.open.name) {
      return const Ok(InviteMode.open);
    }
    if (value == InviteMode.approval.name) {
      return const Ok(InviteMode.approval);
    }
    return Err(MalformedGroupEvent('unknown invite mode $value'));
  }
}
