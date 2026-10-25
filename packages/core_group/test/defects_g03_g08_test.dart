import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/fake_sync.dart';
import 'support/fixtures.dart';

GroupLifecycle lifecycleFor({
  required SyncEngineImpl engine,
  required GroupMetadataStore metadataStore,
  InviteProofVerifier? verifier,
}) {
  return GroupLifecycle(
    syncEngine: engine,
    metadataStore: metadataStore,
    distributor: InMemoryGroupKeyDistributor(),
    inviteProofVerifier: verifier,
  );
}

GroupRenamed renameDraft(
  UserId author, {
  EventId? prevId,
  GroupId groupId = testGroupId,
}) {
  return GroupRenamed(
    id: const EventId(''),
    groupId: groupId,
    authorId: author,
    timestamp: 0,
    prevId: prevId,
    name: 'Renamed',
  );
}

Future<InviteLink> inviteFor(
  GroupId groupId,
  String genesisId,
  FakeIdentity inviter,
) {
  return InviteLink.issue(
    signer: inviter.signer,
    groupId: groupId,
    genesisEventId: EventId(genesisId),
    inviteId: 'inv-1',
    secret: 'secret',
    inviterId: inviter.author,
    expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
  );
}

void main() {
  group('G-03: сериализация метаданных', () {
    test('конкурентные join с разными gen не дают last-write-wins', () async {
      final owner = FakeIdentity(testUserId(1));
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);
      final metadataStore = MemoryGroupMetadataStore();
      final lifecycle = lifecycleFor(
        engine: engine,
        metadataStore: metadataStore,
        verifier: allowAllProofs,
      );
      const groupId = GroupId('join-race');

      final results = await Future.wait([
        lifecycle.joinFromInvite(await inviteFor(groupId, 'a' * 64, owner)),
        lifecycle.joinFromInvite(await inviteFor(groupId, 'b' * 64, owner)),
      ]);

      expect(results.where((result) => result.isOk), hasLength(1));
      expect(
        results.where((result) => result.isErr).single.unwrapErr(),
        isA<GroupRootConflict>(),
      );
      final stored = (await metadataStore.load(groupId)).unwrap()!;
      expect(
        stored.genesisEventId,
        isIn([EventId('a' * 64), EventId('b' * 64)]),
      );
      expect((await metadataStore.loadActiveGroup()).unwrap(), groupId);
    });

    test(
      'recovery идемпотентно досоздаёт MemberAdded начальным участникам',
      () async {
        final owner = FakeIdentity(testUserId(1));
        final alice = testUserId(2);
        final bob = testUserId(3);
        final engine = SyncEngineImpl(
          store: MemorySyncEventStore(),
          signer: owner.signer,
          localAuthor: owner.author,
        );
        addTearDown(engine.close);
        const groupId = GroupId('recover-members');
        const codec = GroupEventCodec();
        final payload = codec
            .encode(
              GroupCreated(
                id: const EventId(''),
                groupId: groupId,
                authorId: owner.author,
                timestamp: 0,
                name: 'Recovered',
                ownerId: owner.author,
                initialMembers: {owner.author, alice, bob},
              ),
            )
            .unwrap();
        final genesis = await engine.createEvent(
          groupId: groupId,
          kind: SyncEventKind.groupCreated,
          payload: payload,
        );
        final metadataStore = MemoryGroupMetadataStore();
        await metadataStore.save(
          await signedMetadata(
            const GroupMetadata(
              groupId: groupId,
              origin: GroupOrigin.created,
              createdAt: 1,
            ),
            owner,
          ),
        );
        final lifecycle = lifecycleFor(
          engine: engine,
          metadataStore: metadataStore,
        );

        expect((await lifecycle.recoverPendingGroups()).isOk, isTrue);
        expect((await lifecycle.recoverPendingGroups()).isOk, isTrue);

        final events = await engine.allEvents(groupId);
        expect(
          events.where((event) => event.kind == SyncEventKind.groupCreated),
          hasLength(1),
        );
        expect(
          events
              .firstWhere((event) => event.kind == SyncEventKind.groupCreated)
              .id,
          genesis.unwrap().id,
        );
        final memberTargets = events
            .where((event) => event.kind == SyncEventKind.memberAdded)
            .map((event) => event.targetId)
            .toList();
        expect(memberTargets, unorderedEquals([alice.value, bob.value]));
      },
    );
  });

  group('G-04: publish валидирует до записи', () {
    test('Forbidden не пишется в лог и не gossip-ится', () async {
      final owner = FakeIdentity(testUserId(1));
      final bob = FakeIdentity(testUserId(2));
      final store = MemorySyncEventStore();
      final ownerEngine = SyncEngineImpl(
        store: store,
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(ownerEngine.close);
      final created = await GroupSyncBridge.create(
        syncEngine: ownerEngine,
        groupId: testGroupId,
        name: 'Owner group',
        initialMembers: {owner.author, bob.author},
        distributor: InMemoryGroupKeyDistributor(),
        inviteProofVerifier: allowAllProofs,
      );
      final ownerBridge = created.unwrap();
      addTearDown(ownerBridge.close);
      await ownerBridge.close();

      final bobEngine = SyncEngineImpl(
        store: store,
        signer: bob.signer,
        localAuthor: bob.author,
      );
      addTearDown(bobEngine.close);
      final genesis = (await bobEngine.allEvents(testGroupId))
          .firstWhere((event) => event.kind == SyncEventKind.groupCreated);
      final bridge = GroupSyncBridge(
        syncEngine: bobEngine,
        groupId: testGroupId,
        controller: GroupController(
          distributor: InMemoryGroupKeyDistributor(),
          expectedGroupId: testGroupId,
          genesisEventId: genesis.id,
          inviteProofVerifier: allowAllProofs,
        ),
      );
      addTearDown(bridge.close);
      expect((await bridge.start()).isOk, isTrue);

      final result = await bridge.publish(renameDraft(bob.author));

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<ControllerFailure>());
      expect((result.unwrapErr() as ControllerFailure).error, isA<Forbidden>());
      final events = await bobEngine.allEvents(testGroupId);
      expect(
        events.where((event) => event.kind == SyncEventKind.groupRenamed),
        isEmpty,
      );
    });
  });

  group('G-05: восстановление проверяет подпись', () {
    test('подменённая подпись в store не применяется', () async {
      final owner = FakeIdentity(testUserId(1));
      final store = MemorySyncEventStore();
      final metadataStore = MemoryGroupMetadataStore();
      final engine = SyncEngineImpl(
        store: store,
        signer: owner.signer,
        localAuthor: owner.author,
      );
      final lifecycle = lifecycleFor(
        engine: engine,
        metadataStore: metadataStore,
      );
      final created = await lifecycle.createGroup(name: 'Original');
      final groupId = created.unwrap();
      final bridge = (await lifecycle.open(groupId)).unwrap();
      final renamed = await bridge.publish(
        renameDraft(owner.author, prevId: bridge.nextPrevId, groupId: groupId),
      );
      expect(renamed.isOk, isTrue);
      await bridge.close();
      await engine.close();

      final records = await store.groupEvents(groupId);
      final target = records.last;
      store.replace(
        EventRecord(
          id: target.id,
          groupId: target.groupId,
          channelId: target.channelId,
          author: target.author,
          payload: target.payload,
          timestamp: target.timestamp,
          signature: '00${target.signature}',
        ),
      );

      final restarted = SyncEngineImpl(
        store: store,
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(restarted.close);
      final reopened = await lifecycleFor(
        engine: restarted,
        metadataStore: metadataStore,
      ).open(groupId);

      expect(reopened.isOk, isTrue);
      final restored = reopened.unwrap();
      addTearDown(restored.close);
      expect(restored.state.name, 'Original');
    });
  });

  group('G-06: invite без verifier запрещён явно', () {
    test('joinFromInvite не активирует группу без proof verifier', () async {
      final owner = FakeIdentity(testUserId(1));
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);
      final metadataStore = MemoryGroupMetadataStore();
      final lifecycle = lifecycleFor(
        engine: engine,
        metadataStore: metadataStore,
      );
      const groupId = GroupId('invite-disabled');

      final joined = await lifecycle.joinFromInvite(
        await inviteFor(groupId, 'a' * 64, owner),
      );

      expect(joined.isErr, isTrue);
      expect((await metadataStore.load(groupId)).unwrap(), isNull);
      expect((await metadataStore.loadActiveGroup()).unwrap(), isNull);
    });
  });

  group('G-08: payload и envelope согласованы', () {
    test('MemberAdded с чужим targetId отклоняется', () {
      final draft = added(id: 'add-1', userId: alice);
      final payload = codec.encode(draft).unwrap();
      final event = SyncEvent(
        id: const EventId('id'),
        groupId: testGroupId,
        authorId: owner,
        hlc: Hlc(draft.timestamp, draft.counter),
        kind: SyncEventKind.memberAdded,
        targetId: bob.value,
        payload: payload,
      );

      final decoded = codec.decode(event);

      expect(decoded.isErr, isTrue);
      expect(decoded.unwrapErr(), isA<MalformedGroupEvent>());
    });

    test('ChannelCreated с чужим channelId отклоняется', () {
      final draft = channelCreated(id: 'channel-1', channelId: 'general');
      final payload = codec.encode(draft).unwrap();
      final event = SyncEvent(
        id: const EventId('id'),
        groupId: testGroupId,
        authorId: owner,
        hlc: Hlc(draft.timestamp, draft.counter),
        kind: SyncEventKind.channelCreated,
        channelId: const ChannelId('other'),
        targetId: 'general',
        payload: payload,
      );

      final decoded = codec.decode(event);

      expect(decoded.isErr, isTrue);
      expect(decoded.unwrapErr(), isA<MalformedGroupEvent>());
    });
  });
}

const codec = GroupEventCodec();
