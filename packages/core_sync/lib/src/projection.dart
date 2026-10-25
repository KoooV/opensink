import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:core_protocol/core_protocol.dart' show GroupEvent;

import 'hlc.dart';
import 'sync_event.dart';

enum MembershipStatus { member, notMember, unknown }

/// Согласованность индексов envelope с полями payload группового события.
///
/// `core_sync` не разбирает доменные события, но для событий, влияющих на
/// членство, берёт те же поля, что и `core_group`. Пустой/битый payload
/// считается legacy и обрабатывается по envelope.
bool _hasConsistentEnvelope(SyncEvent event) {
  if (!_isMembershipKind(event.kind)) return true;
  final payload = _decodeGroupPayload(event);
  if (payload == null || payload.eventType != event.kind.code) return true;
  bool matches(String? envelope, String? value) =>
      value == null || value.isEmpty || envelope == value;
  return switch (event.kind) {
    SyncEventKind.memberAdded ||
    SyncEventKind.memberRemoved ||
    SyncEventKind.roleSet => matches(event.targetId, payload.userId),
    SyncEventKind.memberApproved =>
      matches(event.targetId, payload.userId) && payload.inviteId.isNotEmpty,
    SyncEventKind.ownerTransferred => matches(
      event.targetId,
      payload.newOwnerId,
    ),
    SyncEventKind.inviteIssued ||
    SyncEventKind.memberJoined => matches(event.targetId, payload.inviteId),
    SyncEventKind.channelCreated || SyncEventKind.channelDeleted =>
      payload.channelId.isNotEmpty &&
          matches(event.channelId?.value, payload.channelId) &&
          matches(event.targetId, payload.channelId),
    _ => true,
  };
}

bool _isMembershipKind(SyncEventKind kind) => switch (kind) {
  SyncEventKind.groupCreated ||
  SyncEventKind.memberAdded ||
  SyncEventKind.memberRemoved ||
  SyncEventKind.ownerTransferred ||
  SyncEventKind.inviteIssued ||
  SyncEventKind.memberJoined ||
  SyncEventKind.memberApproved ||
  SyncEventKind.roleSet ||
  SyncEventKind.channelCreated ||
  SyncEventKind.channelDeleted => true,
  _ => false,
};

GroupEvent? _decodeGroupPayload(SyncEvent event) {
  if (event.payload.isEmpty) return null;
  try {
    return GroupEvent.fromBytes(event.payload);
  } catch (_) {
    return null;
  }
}

/// Чистая проверка членства автора на момент события.
///
/// События применяются в детерминированном порядке `(HLC, id)`. Если автор
/// когда-либо был добавлен, но к моменту события уже удалён — `notMember`.
/// Если автор вообще не встречался в известной истории — `unknown`
/// (событие откладывается до получения membership-события).
class MembershipEvaluator {
  const MembershipEvaluator();

  MembershipStatus evaluate(SyncEvent event, Iterable<SyncEvent> timeline) {
    if (event.kind == SyncEventKind.groupCreated) {
      return MembershipStatus.member;
    }
    if (!_hasConsistentEnvelope(event)) {
      return MembershipStatus.notMember;
    }

    final members = <String>{};
    final everMembers = <String>{};
    final inviteModes = <String, bool>{};
    var sawGroup = false;

    for (final candidate in timeline) {
      if (candidate.compareTo(event) >= 0) break;
      if (!_hasConsistentEnvelope(candidate)) continue;
      switch (candidate.kind) {
        case SyncEventKind.groupCreated:
          sawGroup = true;
          members.add(candidate.authorId.value);
          everMembers.add(candidate.authorId.value);
        case SyncEventKind.memberAdded:
          sawGroup = true;
          final user = candidate.targetId;
          if (user != null) {
            members.add(user);
            everMembers.add(user);
          }
        case SyncEventKind.memberRemoved:
          sawGroup = true;
          final user = candidate.targetId;
          if (user != null) {
            members.remove(user);
            everMembers.add(user);
          }
        case SyncEventKind.ownerTransferred:
          sawGroup = true;
          final user = candidate.targetId;
          if (user != null) {
            members.add(user);
            everMembers.add(user);
          }
        case SyncEventKind.inviteIssued:
          sawGroup = true;
          final invite = _decodeGroupEvent(candidate);
          final inviteId = invite?.inviteId ?? candidate.targetId;
          if (inviteId != null && inviteId.isNotEmpty) {
            inviteModes[inviteId] = invite?.inviteMode == 'open';
          }
        case SyncEventKind.memberJoined:
          sawGroup = true;
          final inviteId = _inviteIdOf(candidate);
          final isOpen = inviteId == null ? null : inviteModes[inviteId];
          final author = candidate.authorId.value;
          if (isOpen == true) {
            members.add(author);
            everMembers.add(author);
          } else if (isOpen == false) {
            everMembers.add(author);
          }
        case SyncEventKind.memberApproved:
          sawGroup = true;
          final user = candidate.targetId;
          if (user != null) {
            members.add(user);
            everMembers.add(user);
          }
        case SyncEventKind.roleSet:
        case SyncEventKind.keyRotated:
        case SyncEventKind.channelCreated:
        case SyncEventKind.channelDeleted:
        case SyncEventKind.groupRenamed:
        case SyncEventKind.messageCreated:
        case SyncEventKind.messageEdited:
        case SyncEventKind.messageDeleted:
          sawGroup = true;
      }
    }

    if (event.kind == SyncEventKind.memberJoined && sawGroup) {
      return MembershipStatus.member;
    }
    if (!sawGroup) return MembershipStatus.unknown;
    final author = event.authorId.value;
    if (members.contains(author)) return MembershipStatus.member;
    if (everMembers.contains(author)) return MembershipStatus.notMember;
    return MembershipStatus.unknown;
  }

  GroupEvent? _decodeGroupEvent(SyncEvent event) {
    try {
      return GroupEvent.fromBytes(event.payload);
    } catch (_) {
      return null;
    }
  }

  String? _inviteIdOf(SyncEvent event) {
    final decoded = _decodeGroupEvent(event);
    final inviteId = decoded?.inviteId;
    if (inviteId != null && inviteId.isNotEmpty) return inviteId;
    return event.targetId;
  }
}

/// Проекция состояния группы из множества событий.
///
/// Это чистая функция: результат зависит только от набора событий, не от
/// порядка доставки. Tombstones остаются в логе, но меняют проекцию сообщения.
class GroupProjection {
  const GroupProjection({
    required this.eventIds,
    required this.memberIds,
    required this.messages,
  });

  final List<String> eventIds;
  final Set<String> memberIds;
  final Map<String, ProjectedMessage> messages;

  factory GroupProjection.fromEvents(Iterable<SyncEvent> events) {
    final sorted = events.toList()..sort((a, b) => a.compareTo(b));
    final members = <String>{};
    final inviteModes = <String, bool>{};
    final created = <String, ProjectedMessage>{};

    for (final event in sorted) {
      if (!_hasConsistentEnvelope(event)) continue;
      switch (event.kind) {
        case SyncEventKind.groupCreated:
          members.add(event.authorId.value);
        case SyncEventKind.memberAdded:
          final user = event.targetId;
          if (user != null) members.add(user);
        case SyncEventKind.memberRemoved:
          final user = event.targetId;
          if (user != null) members.remove(user);
        case SyncEventKind.ownerTransferred:
          final user = event.targetId;
          if (user != null) members.add(user);
        case SyncEventKind.inviteIssued:
          final invite = _decodeInvite(event);
          final inviteId = invite?.inviteId ?? event.targetId;
          if (inviteId != null && inviteId.isNotEmpty) {
            inviteModes[inviteId] = invite?.inviteMode == 'open';
          }
        case SyncEventKind.memberJoined:
          final inviteId = _decodeInvite(event)?.inviteId ?? event.targetId;
          if (inviteId != null && inviteModes[inviteId] == true) {
            members.add(event.authorId.value);
          }
        case SyncEventKind.memberApproved:
          final user = event.targetId;
          if (user != null) members.add(user);
        case SyncEventKind.messageCreated:
          created[event.id.value] = ProjectedMessage(
            id: event.id.value,
            channelId: event.channelId?.value ?? '',
            authorId: event.authorId.value,
            content: utf8.decode(event.payload, allowMalformed: true),
            deleted: false,
            edited: false,
            hlc: event.hlc,
          );
        case SyncEventKind.roleSet:
        case SyncEventKind.keyRotated:
        case SyncEventKind.channelCreated:
        case SyncEventKind.channelDeleted:
        case SyncEventKind.groupRenamed:
        case SyncEventKind.messageEdited:
        case SyncEventKind.messageDeleted:
          break;
      }
    }

    final messages = Map<String, ProjectedMessage>.from(created);
    for (final event in sorted) {
      final target = event.targetId;
      if (target == null) continue;
      final current = messages[target];
      if (current == null) continue;
      if (current.authorId != event.authorId.value) continue;

      switch (event.kind) {
        case SyncEventKind.messageEdited:
          messages[target] = current.copyWith(
            content: utf8.decode(event.payload, allowMalformed: true),
            edited: true,
          );
        case SyncEventKind.messageDeleted:
          messages[target] = current.copyWith(content: '', deleted: true);
        case SyncEventKind.groupCreated:
        case SyncEventKind.memberAdded:
        case SyncEventKind.memberRemoved:
        case SyncEventKind.channelCreated:
        case SyncEventKind.channelDeleted:
        case SyncEventKind.groupRenamed:
        case SyncEventKind.ownerTransferred:
        case SyncEventKind.messageCreated:
        case SyncEventKind.inviteIssued:
        case SyncEventKind.memberJoined:
        case SyncEventKind.memberApproved:
        case SyncEventKind.roleSet:
        case SyncEventKind.keyRotated:
          break;
      }
    }

    final eventIds = sorted.map((event) => event.id.value).toList();
    return GroupProjection(
      eventIds: eventIds,
      memberIds: members,
      messages: messages,
    );
  }

  static GroupEvent? _decodeInvite(SyncEvent event) {
    try {
      return GroupEvent.fromBytes(event.payload);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupProjection &&
          const ListEquality<String>().equals(eventIds, other.eventIds) &&
          const SetEquality<String>().equals(memberIds, other.memberIds) &&
          const MapEquality<String, ProjectedMessage>().equals(
            messages,
            other.messages,
          );

  @override
  int get hashCode => Object.hash(
    const ListEquality<String>().hash(eventIds),
    const SetEquality<String>().hash(memberIds),
    const MapEquality<String, ProjectedMessage>().hash(messages),
  );

  @override
  String toString() =>
      'GroupProjection(events=${eventIds.length}, members=${memberIds.length}, '
      'messages=${messages.length})';
}

class ProjectedMessage {
  const ProjectedMessage({
    required this.id,
    required this.channelId,
    required this.authorId,
    required this.content,
    required this.deleted,
    required this.edited,
    required this.hlc,
  });

  final String id;
  final String channelId;
  final String authorId;
  final String content;
  final bool deleted;
  final bool edited;
  final Hlc hlc;

  ProjectedMessage copyWith({String? content, bool? deleted, bool? edited}) {
    return ProjectedMessage(
      id: id,
      channelId: channelId,
      authorId: authorId,
      content: content ?? this.content,
      deleted: deleted ?? this.deleted,
      edited: edited ?? this.edited,
      hlc: hlc,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectedMessage &&
          id == other.id &&
          channelId == other.channelId &&
          authorId == other.authorId &&
          content == other.content &&
          deleted == other.deleted &&
          edited == other.edited &&
          hlc == other.hlc;

  @override
  int get hashCode =>
      Object.hash(id, channelId, authorId, content, deleted, edited, hlc);

  @override
  String toString() =>
      'ProjectedMessage(id=$id, channel=$channelId, deleted=$deleted, '
      'edited=$edited, content=$content)';
}
