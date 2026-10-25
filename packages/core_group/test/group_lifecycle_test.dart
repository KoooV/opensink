import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/fake_sync.dart';
import 'support/fixtures.dart';

GroupLifecycle lifecycleFor({
  required SyncEngineImpl engine,
  required GroupMetadataStore metadataStore,
  InviteProofVerifier? inviteProofVerifier,
}) {
  return GroupLifecycle(
    syncEngine: engine,
    metadataStore: metadataStore,
    distributor: InMemoryGroupKeyDistributor(),
    inviteProofVerifier: inviteProofVerifier ?? allowAllProofs,
  );
}

void main() {
  group('GroupLifecycle', () {
    test('create сохраняет genesis и переживает рестарт', () async {
      final owner = FakeIdentity(testUserId(1));
      final store = MemorySyncEventStore();
      final metadataStore = MemoryGroupMetadataStore();
      final engine = SyncEngineImpl(
        store: store,
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);
      final lifecycle = lifecycleFor(
        engine: engine,
        metadataStore: metadataStore,
      );

      final created = await lifecycle.createGroup(name: 'Created');

      expect(created.isOk, isTrue);
      final groupId = created.unwrap();
      final metadata = (await metadataStore.load(groupId)).unwrap();
      expect(metadata, isNotNull);
      expect(metadata!.isReady, isTrue);
      expect(metadata.origin, GroupOrigin.created);
      expect((await metadataStore.loadActiveGroup()).unwrap(), groupId);

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
      final bridge = reopened.unwrap();
      addTearDown(bridge.close);
      expect(bridge.state.name, 'Created');
      expect(bridge.state.memberIds, {owner.author});
    });

    test('open без метаданных не создаёт группу', () async {
      final owner = FakeIdentity(testUserId(1));
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);
      final lifecycle = lifecycleFor(
        engine: engine,
        metadataStore: MemoryGroupMetadataStore(),
      );

      final opened = await lifecycle.open(const GroupId('unknown'));

      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<GroupNotFound>());
      expect(await engine.allEvents(const GroupId('unknown')), isEmpty);
    });

    test('join сохраняет корень из инвайта до приёма событий', () async {
      final owner = FakeIdentity(testUserId(1));
      final bob = FakeIdentity(testUserId(2));
      final ownerStore = MemorySyncEventStore();
      final ownerEngine = SyncEngineImpl(
        store: ownerStore,
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(ownerEngine.close);
      final ownerMetadata = MemoryGroupMetadataStore();
      final created = await lifecycleFor(
        engine: ownerEngine,
        metadataStore: ownerMetadata,
      ).createGroup(name: 'Invite group');
      final groupId = created.unwrap();
      final genesisId = (await ownerMetadata.load(groupId))
          .unwrap()!
          .genesisEventId!;

      final bobStore = MemorySyncEventStore();
      final bobEngine = SyncEngineImpl(
        store: bobStore,
        signer: bob.signer,
        localAuthor: bob.author,
      );
      addTearDown(bobEngine.close);
      final bobMetadata = MemoryGroupMetadataStore();
      final bobLifecycle = lifecycleFor(
        engine: bobEngine,
        metadataStore: bobMetadata,
      );
      final link = InviteLink(
        groupId: groupId,
        genesisEventId: genesisId,
        inviteId: 'inv-1',
        secret: 'secret',
        inviterId: owner.author,
      );

      final joined = await bobLifecycle.joinFromInvite(link);

      expect(joined.isOk, isTrue);
      final stored = (await bobMetadata.load(groupId)).unwrap()!;
      expect(stored.genesisEventId, genesisId);
      expect(stored.origin, GroupOrigin.invited);
      expect((await bobMetadata.loadActiveGroup()).unwrap(), groupId);

      final opened = await bobLifecycle.open(groupId);
      expect(opened.isOk, isTrue);
      final bridge = opened.unwrap();
      addTearDown(bridge.close);
      expect(bridge.state.memberIds, isEmpty);

      final genesis = (await ownerEngine.allEvents(groupId))
          .firstWhere((event) => event.kind == SyncEventKind.groupCreated);
      final updated = bridge.watch().first;
      expect((await bobEngine.ingest(genesis)).isOk, isTrue);
      await updated.timeout(const Duration(seconds: 2));

      expect(bridge.state.name, 'Invite group');
    });

    test(
      'join с другим genesis отклоняется и не перезаписывает метаданные',
      () async {
        const groupId = GroupId('group');
        final metadataStore = MemoryGroupMetadataStore();
        const existing = GroupMetadata(
          groupId: groupId,
          genesisEventId: EventId('gen-a'),
          origin: GroupOrigin.created,
          createdAt: 1,
        );
        await metadataStore.save(existing);
        final owner = FakeIdentity(testUserId(1));
        final engine = SyncEngineImpl(
          store: MemorySyncEventStore(),
          signer: owner.signer,
          localAuthor: owner.author,
        );
        addTearDown(engine.close);
        final lifecycle = lifecycleFor(
          engine: engine,
          metadataStore: metadataStore,
        );

        final joined = await lifecycle.joinFromInvite(
          InviteLink(
            groupId: groupId,
            genesisEventId: const EventId('gen-b'),
            inviteId: 'inv-1',
            secret: 'secret',
            inviterId: owner.author,
          ),
        );

        expect(joined.isErr, isTrue);
        expect(joined.unwrapErr(), isA<GroupRootConflict>());
        expect((await metadataStore.load(groupId)).unwrap(), existing);
      },
    );

    test(
      'pending create восстанавливается по единственному local genesis',
      () async {
        final owner = FakeIdentity(testUserId(1));
        final engine = SyncEngineImpl(
          store: MemorySyncEventStore(),
          signer: owner.signer,
          localAuthor: owner.author,
        );
        addTearDown(engine.close);
        const groupId = GroupId('pending');
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
                initialMembers: {owner.author},
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
          const GroupMetadata(
            groupId: groupId,
            origin: GroupOrigin.created,
            createdAt: 1,
          ),
        );
        final lifecycle = lifecycleFor(
          engine: engine,
          metadataStore: metadataStore,
        );

        final recovered = await lifecycle.recoverPendingGroups();

        expect(recovered.isOk, isTrue);
        final metadata = (await metadataStore.load(groupId)).unwrap()!;
        expect(metadata.genesisEventId, genesis.unwrap().id);
        final opened = await lifecycle.open(groupId);
        expect(opened.isOk, isTrue);
        final bridge = opened.unwrap();
        addTearDown(bridge.close);
        expect(bridge.state.name, 'Recovered');
      },
    );

    test(
      'pending create игнорирует чужой genesis при восстановлении',
      () async {
        final owner = FakeIdentity(testUserId(1));
        final attacker = FakeIdentity(testUserId(9));
        final engine = SyncEngineImpl(
          store: MemorySyncEventStore(),
          signer: owner.signer,
          localAuthor: owner.author,
        );
        addTearDown(engine.close);
        const groupId = GroupId('pending-foreign');
        const codec = GroupEventCodec();
        final payload = codec
            .encode(
              GroupCreated(
                id: const EventId(''),
                groupId: groupId,
                authorId: owner.author,
                timestamp: 0,
                name: 'Recovered by owner',
                ownerId: owner.author,
                initialMembers: {owner.author},
              ),
            )
            .unwrap();
        final local = await engine.createEvent(
          groupId: groupId,
          kind: SyncEventKind.groupCreated,
          payload: payload,
        );
        final foreign = await signedEventWith(
          identity: attacker,
          draft: GroupCreated(
            id: const EventId(''),
            groupId: groupId,
            authorId: attacker.author,
            timestamp: 0,
            name: 'Foreign',
            ownerId: attacker.author,
            initialMembers: {attacker.author},
          ),
          hlc: Hlc(engine.lastHlc.physicalMs + 1, 0),
        );
        expect((await engine.ingest(foreign)).isOk, isTrue);

        final metadataStore = MemoryGroupMetadataStore();
        await metadataStore.save(
          const GroupMetadata(
            groupId: groupId,
            origin: GroupOrigin.created,
            createdAt: 1,
          ),
        );
        final lifecycle = lifecycleFor(
          engine: engine,
          metadataStore: metadataStore,
        );

        final recovered = await lifecycle.recoverPendingGroups();

        expect(recovered.isOk, isTrue);
        final metadata = (await metadataStore.load(groupId)).unwrap()!;
        expect(metadata.genesisEventId, local.unwrap().id);
        final opened = await lifecycle.open(groupId);
        expect(opened.isOk, isTrue);
        final bridge = opened.unwrap();
        addTearDown(bridge.close);
        expect(bridge.state.name, 'Recovered by owner');
      },
    );

    test('pending create с чужим корнем не удаляет метаданные', () async {
      final owner = FakeIdentity(testUserId(1));
      final attacker = FakeIdentity(testUserId(9));
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);
      const groupId = GroupId('pending-foreign-only');
      final foreign = await signedEventWith(
        identity: attacker,
        draft: GroupCreated(
          id: const EventId(''),
          groupId: groupId,
          authorId: attacker.author,
          timestamp: 0,
          name: 'Foreign',
          ownerId: attacker.author,
          initialMembers: {attacker.author},
        ),
        hlc: const Hlc(1, 0),
      );
      expect((await engine.ingest(foreign)).isOk, isTrue);
      final metadataStore = MemoryGroupMetadataStore();
      await metadataStore.save(
        const GroupMetadata(
          groupId: groupId,
          origin: GroupOrigin.created,
          createdAt: 1,
        ),
      );

      final recovered = await lifecycleFor(
        engine: engine,
        metadataStore: metadataStore,
      ).recoverPendingGroups();

      expect(recovered.isErr, isTrue);
      expect(recovered.unwrapErr(), isA<GroupRootConflict>());
      expect((await metadataStore.load(groupId)).unwrap(), isNotNull);
    });

    test('pending create без событий удаляется', () async {
      final owner = FakeIdentity(testUserId(1));
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);
      final metadataStore = MemoryGroupMetadataStore();
      const groupId = GroupId('empty-pending');
      await metadataStore.save(
        const GroupMetadata(
          groupId: groupId,
          origin: GroupOrigin.created,
          createdAt: 1,
        ),
      );
      final lifecycle = lifecycleFor(
        engine: engine,
        metadataStore: metadataStore,
      );

      final recovered = await lifecycle.recoverPendingGroups();

      expect(recovered.isOk, isTrue);
      expect((await metadataStore.load(groupId)).unwrap(), isNull);
    });
  });
}
