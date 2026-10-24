import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart'
    show GroupState, InviteProofVerifier;

/// Тестовый fake: любой непустой proof считается валидным.
class AllowAllInviteProofVerifier implements InviteProofVerifier {
  const AllowAllInviteProofVerifier();

  @override
  bool verify({
    required GroupId groupId,
    required String inviteId,
    required UserId userId,
    required String proof,
  }) => proof.isNotEmpty;
}

const allowAllProofs = AllowAllInviteProofVerifier();

/// Строит состояние из событий, автоматически связывая их в цепочки
/// `prevId` по автору — так тесты не дублируют ручное связывание.
GroupState buildState(
  Iterable<GroupEvent> events, {
  GroupId? expectedGroupId,
  EventId? genesisEventId,
  InviteProofVerifier? inviteProofVerifier,
}) {
  final all = events.toList();
  GroupCreated? creation;
  for (final event in all) {
    if (event is GroupCreated) {
      creation = event;
      break;
    }
  }
  if (creation == null) {
    throw StateError('buildState requires a GroupCreated event');
  }
  return GroupState.fromEvents(
    linked(all),
    expectedGroupId: expectedGroupId ?? creation.groupId,
    genesisEventId: genesisEventId ?? creation.id,
    inviteProofVerifier: inviteProofVerifier ?? allowAllProofs,
  );
}

List<GroupEvent> linked(Iterable<GroupEvent> events) {
  final unique = <String, GroupEvent>{};
  for (final event in events) {
    unique.putIfAbsent(event.id.value, () => event);
  }
  final sorted = unique.values.toList()..sort(GroupState.compareEvents);
  final lastByAuthor = <UserId, EventId>{};
  final result = <GroupEvent>[];
  for (final event in sorted) {
    final prevId = event is GroupCreated ? null : lastByAuthor[event.authorId];
    final next = withPrevId(event, prevId);
    result.add(next);
    lastByAuthor[event.authorId] = next.id;
  }
  return result;
}

GroupEvent withPrevId(GroupEvent event, EventId? prevId) {
  return switch (event) {
    GroupCreated e => GroupCreated(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      name: e.name,
      ownerId: e.ownerId,
      initialMembers: e.initialMembers,
    ),
    MemberAdded e => MemberAdded(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      prevId: prevId,
      userId: e.userId,
    ),
    MemberRemoved e => MemberRemoved(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      prevId: prevId,
      userId: e.userId,
    ),
    ChannelCreated e => ChannelCreated(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      prevId: prevId,
      channelId: e.channelId,
      name: e.name,
      type: e.type,
      minViewRole: e.minViewRole,
      minPostRole: e.minPostRole,
    ),
    ChannelDeleted e => ChannelDeleted(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      prevId: prevId,
      channelId: e.channelId,
    ),
    GroupRenamed e => GroupRenamed(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      prevId: prevId,
      name: e.name,
    ),
    OwnerTransferred e => OwnerTransferred(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      prevId: prevId,
      newOwnerId: e.newOwnerId,
    ),
    InviteIssued e => InviteIssued(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      prevId: prevId,
      inviteId: e.inviteId,
      mode: e.mode,
      maxUses: e.maxUses,
      expiresAt: e.expiresAt,
      relayHint: e.relayHint,
    ),
    MemberJoined e => MemberJoined(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      prevId: prevId,
      inviteId: e.inviteId,
      inviteProof: e.inviteProof,
    ),
    MemberApproved e => MemberApproved(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      prevId: prevId,
      userId: e.userId,
      inviteId: e.inviteId,
    ),
    RoleSet e => RoleSet(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      prevId: prevId,
      userId: e.userId,
      role: e.role,
    ),
    KeyRotated e => KeyRotated(
      id: e.id,
      groupId: e.groupId,
      authorId: e.authorId,
      timestamp: e.timestamp,
      counter: e.counter,
      prevId: prevId,
      newEpoch: e.newEpoch,
    ),
  };
}

const UserId owner = UserId('owner');
const UserId alice = UserId('alice');
const UserId bob = UserId('bob');
const UserId carol = UserId('carol');
const UserId dave = UserId('dave');

const GroupId testGroupId = GroupId('group-1');

GroupCreated created({
  String id = 'create',
  GroupId groupId = testGroupId,
  Set<UserId>? initialMembers,
  int timestamp = 0,
  int counter = 0,
  EventId? prevId,
}) {
  return GroupCreated(
    id: EventId(id),
    groupId: groupId,
    authorId: owner,
    timestamp: timestamp,
    counter: counter,
    prevId: prevId,
    name: 'Test group',
    ownerId: owner,
    initialMembers: initialMembers ?? {owner, alice, bob},
  );
}

InviteIssued inviteIssued({
  String id = 'invite-1',
  String inviteId = 'inv-1',
  UserId authorId = owner,
  InviteMode mode = InviteMode.open,
  int? maxUses = 1,
  int? expiresAt,
  int timestamp = 10,
  int counter = 0,
}) {
  return InviteIssued(
    id: EventId(id),
    groupId: testGroupId,
    authorId: authorId,
    timestamp: timestamp,
    counter: counter,
    inviteId: inviteId,
    mode: mode,
    maxUses: maxUses,
    expiresAt: expiresAt,
  );
}

MemberJoined joined({
  String id = 'join-1',
  String inviteId = 'inv-1',
  required UserId userId,
  String inviteProof = 'test-proof',
  int timestamp = 20,
  int counter = 0,
  EventId? prevId,
}) {
  return MemberJoined(
    id: EventId(id),
    groupId: testGroupId,
    authorId: userId,
    timestamp: timestamp,
    counter: counter,
    prevId: prevId,
    inviteId: inviteId,
    inviteProof: inviteProof,
  );
}

MemberApproved approved({
  String id = 'approve-1',
  String inviteId = 'inv-1',
  required UserId userId,
  UserId authorId = owner,
  int timestamp = 30,
  int counter = 0,
}) {
  return MemberApproved(
    id: EventId(id),
    groupId: testGroupId,
    authorId: authorId,
    timestamp: timestamp,
    counter: counter,
    userId: userId,
    inviteId: inviteId,
  );
}

RoleSet roleSet({
  String id = 'role-1',
  required UserId userId,
  required GroupRole role,
  UserId authorId = owner,
  int timestamp = 12,
  int counter = 0,
  EventId? prevId,
}) {
  return RoleSet(
    id: EventId(id),
    groupId: testGroupId,
    authorId: authorId,
    timestamp: timestamp,
    counter: counter,
    prevId: prevId,
    userId: userId,
    role: role,
  );
}

MemberRemoved removed({
  String id = 'remove-1',
  required UserId userId,
  UserId authorId = owner,
  int timestamp = 40,
  int counter = 0,
}) {
  return MemberRemoved(
    id: EventId(id),
    groupId: testGroupId,
    authorId: authorId,
    timestamp: timestamp,
    counter: counter,
    userId: userId,
  );
}

MemberAdded added({
  String id = 'add-1',
  required UserId userId,
  UserId authorId = owner,
  int timestamp = 15,
  int counter = 0,
}) {
  return MemberAdded(
    id: EventId(id),
    groupId: testGroupId,
    authorId: authorId,
    timestamp: timestamp,
    counter: counter,
    userId: userId,
  );
}

ChannelCreated channelCreated({
  String id = 'channel-1',
  String channelId = 'general',
  UserId authorId = owner,
  GroupRole minViewRole = GroupRole.member,
  GroupRole minPostRole = GroupRole.member,
  int timestamp = 16,
  int counter = 0,
}) {
  return ChannelCreated(
    id: EventId(id),
    groupId: testGroupId,
    authorId: authorId,
    timestamp: timestamp,
    counter: counter,
    channelId: ChannelId(channelId),
    name: 'General',
    type: 'text',
    minViewRole: minViewRole,
    minPostRole: minPostRole,
  );
}

ChannelDeleted channelDeleted({
  String id = 'channel-delete-1',
  String channelId = 'general',
  UserId authorId = owner,
  int timestamp = 50,
  int counter = 0,
}) {
  return ChannelDeleted(
    id: EventId(id),
    groupId: testGroupId,
    authorId: authorId,
    timestamp: timestamp,
    counter: counter,
    channelId: ChannelId(channelId),
  );
}

GroupRenamed renamed({
  String id = 'rename-1',
  String name = 'Renamed',
  UserId authorId = owner,
  int timestamp = 60,
  int counter = 0,
  EventId? prevId,
}) {
  return GroupRenamed(
    id: EventId(id),
    groupId: testGroupId,
    authorId: authorId,
    timestamp: timestamp,
    counter: counter,
    prevId: prevId,
    name: name,
  );
}

KeyRotated keyRotated({
  String id = 'key-rotate-1',
  int newEpoch = 2,
  UserId authorId = owner,
  int timestamp = 70,
  int counter = 0,
}) {
  return KeyRotated(
    id: EventId(id),
    groupId: testGroupId,
    authorId: authorId,
    timestamp: timestamp,
    counter: counter,
    newEpoch: newEpoch,
  );
}
