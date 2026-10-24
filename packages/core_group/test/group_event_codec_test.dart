import 'dart:typed_data';

import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

const codec = GroupEventCodec();
const syncCodec = SyncEventCodec();

SyncEvent envelopeFor(GroupEvent draft) {
  final payload = codec.encode(draft).unwrap();
  final base = SyncEvent(
    id: const EventId(''),
    groupId: draft.groupId,
    authorId: draft.authorId,
    hlc: Hlc(draft.timestamp, draft.counter),
    kind: codec.kindOf(draft),
    channelId: codec.channelIdOf(draft),
    targetId: codec.targetIdOf(draft),
    payload: payload,
  );
  return base.copyWith(id: EventId(base.computeId()));
}

GroupEvent decodeThroughEnvelope(GroupEvent draft) {
  final envelope = envelopeFor(draft);
  final bytes = syncCodec.encode(envelope).unwrap();
  final restoredEnvelope = syncCodec.decode(Uint8List.fromList(bytes)).unwrap();
  return codec.decode(restoredEnvelope).unwrap();
}

Map<String, Object?> withoutId(GroupEvent event) {
  final map = Map<String, Object?>.from(event.toCanonicalMap());
  map.remove('id');
  return map;
}

void main() {
  group('GroupEventCodec round-trip', () {
    final events = <GroupEvent>[
      created(initialMembers: {owner, alice, bob}),
      added(id: 'add-1', userId: dave, timestamp: 15),
      removed(id: 'remove-1', userId: bob, timestamp: 20),
      channelCreated(
        id: 'channel-1',
        channelId: 'general',
        minViewRole: GroupRole.moderator,
        minPostRole: GroupRole.admin,
        timestamp: 25,
      ),
      channelDeleted(id: 'channel-del-1', channelId: 'general', timestamp: 30),
      renamed(id: 'rename-1', name: 'Renamed', timestamp: 35),
      const OwnerTransferred(
        id: EventId('transfer-1'),
        groupId: testGroupId,
        authorId: owner,
        timestamp: 40,
        counter: 2,
        newOwnerId: alice,
      ),
      inviteIssued(
        id: 'invite-1',
        inviteId: 'inv-1',
        mode: InviteMode.approval,
        maxUses: 3,
        expiresAt: 120,
        timestamp: 45,
      ),
      joined(
        id: 'join-1',
        inviteId: 'inv-1',
        userId: carol,
        inviteProof: 'proof-1',
        timestamp: 50,
      ),
      approved(
        id: 'approve-1',
        inviteId: 'inv-1',
        userId: carol,
        timestamp: 55,
      ),
      roleSet(
        id: 'role-1',
        userId: alice,
        role: GroupRole.admin,
        timestamp: 60,
      ),
      keyRotated(id: 'rotate-1', newEpoch: 4, timestamp: 65),
    ];

    test('все 12 видов сохраняют поля через SyncEventCodec', () {
      for (final event in events) {
        final decoded = decodeThroughEnvelope(event);
        expect(
          decoded.runtimeType,
          event.runtimeType,
          reason: '${event.runtimeType}',
        );
        expect(
          withoutId(decoded),
          withoutId(event),
          reason: '${event.runtimeType}',
        );
        expect(decoded.groupId, event.groupId);
        expect(decoded.authorId, event.authorId);
        expect(decoded.timestamp, event.timestamp);
        expect(decoded.counter, event.counter);
        expect(decoded.prevId, event.prevId);
      }
    });

    test('kindOf/targetIdOf/channelIdOf согласованы для каждого вида', () {
      for (final event in events) {
        final kind = codec.kindOf(event);
        expect(codec.isGroupEventKind(kind), isTrue);
        expect(kindOfDomain(kind), event.runtimeType);
        expect(envelopeFor(event).targetId, codec.targetIdOf(event));
        expect(envelopeFor(event).channelId, codec.channelIdOf(event));
      }
    });

    test('prevId сохраняется в цепочке автора', () {
      final first = decodeThroughEnvelope(created());
      final secondDraft = renamed(
        id: 'rename-1',
        timestamp: first.timestamp + 1,
        prevId: first.id,
      );
      final second = decodeThroughEnvelope(secondDraft);

      expect(second.prevId, isNotNull);
      expect(second.prevId!.value, isNotEmpty);
    });
  });

  group('GroupEventCodec ошибки', () {
    test('негрупповой kind отклоняется до разбора payload', () {
      final event = SyncEvent(
        id: const EventId('id'),
        groupId: testGroupId,
        authorId: owner,
        hlc: const Hlc(1, 0),
        kind: SyncEventKind.messageCreated,
      );

      final result = codec.decode(event);

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<UnsupportedGroupEvent>());
    });

    test('несовпадение kind и payload.eventType отклоняется', () {
      final payload = codec.encode(created()).unwrap();
      final event = SyncEvent(
        id: const EventId('id'),
        groupId: testGroupId,
        authorId: owner,
        hlc: const Hlc(1, 0),
        kind: SyncEventKind.memberAdded,
        targetId: alice.value,
        payload: payload,
      );

      final result = codec.decode(event);

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<GroupEventKindMismatch>());
    });

    test('битый payload отклоняется как MalformedGroupEvent', () {
      final event = SyncEvent(
        id: const EventId('id'),
        groupId: testGroupId,
        authorId: owner,
        hlc: const Hlc(1, 0),
        kind: SyncEventKind.groupCreated,
        payload: Uint8List.fromList([0xff, 0xff, 0xff]),
      );

      final result = codec.decode(event);

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<MalformedGroupEvent>());
    });
  });
}

Type kindOfDomain(SyncEventKind kind) => switch (kind) {
  SyncEventKind.groupCreated => GroupCreated,
  SyncEventKind.memberAdded => MemberAdded,
  SyncEventKind.memberRemoved => MemberRemoved,
  SyncEventKind.channelCreated => ChannelCreated,
  SyncEventKind.channelDeleted => ChannelDeleted,
  SyncEventKind.groupRenamed => GroupRenamed,
  SyncEventKind.ownerTransferred => OwnerTransferred,
  SyncEventKind.inviteIssued => InviteIssued,
  SyncEventKind.memberJoined => MemberJoined,
  SyncEventKind.memberApproved => MemberApproved,
  SyncEventKind.roleSet => RoleSet,
  SyncEventKind.keyRotated => KeyRotated,
  _ => throw StateError('not a group kind'),
};
