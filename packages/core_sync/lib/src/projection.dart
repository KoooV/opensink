import 'dart:convert';

import 'package:collection/collection.dart';

import 'hlc.dart';
import 'sync_event.dart';

enum MembershipStatus { member, notMember, unknown }

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

    final members = <String>{};
    final everMembers = <String>{};
    var sawGroup = false;

    for (final candidate in timeline) {
      if (candidate.compareTo(event) >= 0) break;
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
        case SyncEventKind.channelCreated:
        case SyncEventKind.channelDeleted:
        case SyncEventKind.groupRenamed:
        case SyncEventKind.messageCreated:
        case SyncEventKind.messageEdited:
        case SyncEventKind.messageDeleted:
          sawGroup = true;
      }
    }

    if (!sawGroup) return MembershipStatus.unknown;
    final author = event.authorId.value;
    if (members.contains(author)) return MembershipStatus.member;
    if (everMembers.contains(author)) return MembershipStatus.notMember;
    return MembershipStatus.unknown;
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
    final created = <String, ProjectedMessage>{};

    for (final event in sorted) {
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
