import 'dart:async';

import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/fake_sync.dart';
import 'support/fixtures.dart';

class Harness {
  Harness({
    required this.owner,
    required this.store,
    required this.engine,
    required this.bridge,
  });

  final FakeIdentity owner;
  final MemorySyncEventStore store;
  final SyncEngineImpl engine;
  final GroupSyncBridge bridge;
}

Future<Harness> createHarness({Set<UserId>? initialMembers}) async {
  final owner = FakeIdentity(testUserId(1));
  final store = MemorySyncEventStore();
  final engine = SyncEngineImpl(
    store: store,
    signer: owner.signer,
    localAuthor: owner.author,
  );
  final created = await GroupSyncBridge.create(
    syncEngine: engine,
    groupId: testGroupId,
    name: 'Test group',
    initialMembers: initialMembers ?? {owner.author},
    distributor: InMemoryGroupKeyDistributor(),
    inviteProofVerifier: allowAllProofs,
  );
  return Harness(
    owner: owner,
    store: store,
    engine: engine,
    bridge: created.unwrap(),
  );
}

GroupRenamed renameDraft(
  UserId author, {
  String name = 'Renamed',
  EventId? prevId,
  GroupId groupId = testGroupId,
}) {
  return GroupRenamed(
    id: const EventId(''),
    groupId: groupId,
    authorId: author,
    timestamp: 0,
    prevId: prevId,
    name: name,
  );
}

void main() {
  group('GroupSyncBridge.create/publish', () {
    test('создаёт genesis и MemberAdded для начальных участников', () async {
      final alice = testUserId(2);
      final harness = await createHarness(
        initialMembers: {testUserId(1), alice},
      );
      addTearDown(harness.bridge.close);
      addTearDown(harness.engine.close);

      expect(harness.bridge.state.name, 'Test group');
      expect(harness.bridge.state.ownerId, harness.owner.author);
      expect(harness.bridge.state.memberIds, containsAll([harness.owner.author, alice]));

      final events = await harness.engine.allEvents(testGroupId);
      expect(
        events.where((event) => event.kind == SyncEventKind.groupCreated),
        hasLength(1),
      );
      expect(
        events.where((event) => event.kind == SyncEventKind.memberAdded),
        hasLength(1),
      );
    });

    test('publish дописывает событие в лог, состояние и поток', () async {
      final harness = await createHarness();
      addTearDown(harness.bridge.close);
      addTearDown(harness.engine.close);

      final next = harness.bridge.watch().first;
      final result = await harness.bridge.publish(
        renameDraft(harness.owner.author, prevId: harness.bridge.nextPrevId),
      );

      expect(result.isOk, isTrue);
      final state = await next.timeout(const Duration(seconds: 2));
      expect(state.name, 'Renamed');
      expect(harness.bridge.state.name, 'Renamed');

      final events = await harness.engine.allEvents(testGroupId);
      expect(events.where((event) => event.kind == SyncEventKind.groupRenamed), hasLength(1));
    });

    test('publish отклоняет чужой groupId, автора и неверный prevId', () async {
      final harness = await createHarness();
      addTearDown(harness.bridge.close);
      addTearDown(harness.engine.close);

      final before = harness.store.length;

      final wrongGroup = await harness.bridge.publish(
        renameDraft(
          harness.owner.author,
          groupId: const GroupId('other'),
          prevId: harness.bridge.nextPrevId,
        ),
      );
      expect(wrongGroup.unwrapErr(), isA<GroupIdMismatchError>());

      final wrongAuthor = await harness.bridge.publish(
        renameDraft(testUserId(2), prevId: harness.bridge.nextPrevId),
      );
      expect(wrongAuthor.unwrapErr(), isA<GroupAuthorMismatch>());

      final wrongPrev = await harness.bridge.publish(
        renameDraft(
          harness.owner.author,
          prevId: const EventId('missing'),
        ),
      );
      expect(wrongPrev.unwrapErr(), isA<MalformedGroupEvent>());

      expect(harness.store.length, before);
    });

    test('publish после close отклоняется', () async {
      final harness = await createHarness();
      addTearDown(harness.engine.close);
      await harness.bridge.close();

      final result = await harness.bridge.publish(
        renameDraft(harness.owner.author, prevId: harness.bridge.nextPrevId),
      );

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<MalformedGroupEvent>());
    });
  });

  group('GroupSyncBridge.start', () {
    test('повторный start восстанавливает историю в новом контроллере', () async {
      final alice = testUserId(2);
      final harness = await createHarness(
        initialMembers: {testUserId(1), alice},
      );
      addTearDown(harness.bridge.close);
      addTearDown(harness.engine.close);

      await harness.bridge.publish(
        renameDraft(harness.owner.author, prevId: harness.bridge.nextPrevId),
      );
      await harness.bridge.publish(
        renameDraft(
          harness.owner.author,
          name: 'Renamed twice',
          prevId: harness.bridge.nextPrevId,
        ),
      );

      final events = await harness.engine.allEvents(testGroupId);
      final genesis = events.firstWhere(
        (event) => event.kind == SyncEventKind.groupCreated,
      );
      final controller = GroupController(
        distributor: InMemoryGroupKeyDistributor(),
        expectedGroupId: testGroupId,
        genesisEventId: genesis.id,
        inviteProofVerifier: allowAllProofs,
      );
      final restored = GroupSyncBridge(
        syncEngine: harness.engine,
        controller: controller,
        groupId: testGroupId,
      );
      addTearDown(restored.close);

      await restored.start();
      await restored.start();

      expect(restored.state.name, 'Renamed twice');
      expect(restored.state.memberIds, harness.bridge.state.memberIds);
      expect(restored.state.ownerId, harness.bridge.state.ownerId);
    });

    test('start идемпотентен и не дублирует события', () async {
      final harness = await createHarness();
      addTearDown(harness.bridge.close);
      addTearDown(harness.engine.close);

      final before = harness.store.length;
      await harness.bridge.start();
      await harness.bridge.start();

      expect(harness.store.length, before);
      expect(harness.bridge.state.memberIds, {harness.owner.author});
    });
  });

  group('GroupSyncBridge инвайты', () {
    test('open-инвайт добавляет вошедшего после refresh', () async {
      final harness = await createHarness();
      addTearDown(harness.bridge.close);
      addTearDown(harness.engine.close);

      final issued = await harness.bridge.publish(
        InviteIssued(
          id: const EventId(''),
          groupId: testGroupId,
          authorId: harness.owner.author,
          timestamp: 0,
          prevId: harness.bridge.nextPrevId,
          inviteId: 'inv-open',
          mode: InviteMode.open,
          maxUses: 5,
        ),
      );
      expect(issued.isOk, isTrue);

      final bob = FakeIdentity(testUserId(3));
      final joinHlc = Hlc(harness.engine.lastHlc.physicalMs + 1, 0);
      final join = await signedEventWith(
        identity: bob,
        hlc: joinHlc,
        draft: MemberJoined(
          id: const EventId('join-bob'),
          groupId: testGroupId,
          authorId: bob.author,
          timestamp: joinHlc.physicalMs,
          inviteId: 'inv-open',
          inviteProof: 'proof',
        ),
      );

      final refreshed = harness.bridge.watch().first;
      final ingested = await harness.engine.ingest(join);
      expect(ingested.unwrap().isInserted, isTrue);
      await refreshed.timeout(const Duration(seconds: 2));

      expect(harness.bridge.state.memberIds, contains(bob.author));
    });

    test('approval-инвайт добавляет участника только после MemberApproved', () async {
      final harness = await createHarness();
      addTearDown(harness.bridge.close);
      addTearDown(harness.engine.close);

      final issued = await harness.bridge.publish(
        InviteIssued(
          id: const EventId(''),
          groupId: testGroupId,
          authorId: harness.owner.author,
          timestamp: 0,
          prevId: harness.bridge.nextPrevId,
          inviteId: 'inv-approval',
          mode: InviteMode.approval,
          maxUses: 5,
        ),
      );
      expect(issued.isOk, isTrue);

      final carol = FakeIdentity(testUserId(4));
      final joinHlc = Hlc(harness.engine.lastHlc.physicalMs + 1, 0);
      final join = await signedEventWith(
        identity: carol,
        hlc: joinHlc,
        draft: MemberJoined(
          id: const EventId('join-carol'),
          groupId: testGroupId,
          authorId: carol.author,
          timestamp: joinHlc.physicalMs,
          inviteId: 'inv-approval',
          inviteProof: 'proof',
        ),
      );

      final joined = harness.bridge.watch().first;
      final ingested = await harness.engine.ingest(join);
      expect(ingested.unwrap().isInserted, isTrue);
      await joined.timeout(const Duration(seconds: 2));
      expect(harness.bridge.state.memberIds, isNot(contains(carol.author)));

      final approved = await harness.bridge.publish(
        MemberApproved(
          id: const EventId(''),
          groupId: testGroupId,
          authorId: harness.owner.author,
          timestamp: 0,
          prevId: harness.bridge.nextPrevId,
          userId: carol.author,
          inviteId: 'inv-approval',
        ),
      );

      expect(approved.isOk, isTrue);
      expect(harness.bridge.state.memberIds, contains(carol.author));
    });
  });
}
