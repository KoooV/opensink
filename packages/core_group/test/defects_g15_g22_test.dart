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
    inviteProofVerifier: verifier ?? allowAllProofs,
  );
}

class FailingPinEngine extends SyncEngineImpl {
  FailingPinEngine({
    required super.store,
    required super.signer,
    required super.localAuthor,
  });

  @override
  Future<Result<void, SyncError>> pinGroupRoot(
    GroupId groupId,
    EventId genesisEventId,
  ) async {
    return const Err(StorageWriteFailure('pin failed'));
  }
}

Future<InviteLink> inviteFor(
  FakeIdentity inviter,
  GroupId groupId,
  EventId genesis, {
  int? expiresAt,
}) {
  return InviteLink.issue(
    signer: inviter.signer,
    groupId: groupId,
    genesisEventId: genesis,
    inviteId: 'inv-1',
    secret: 'secret',
    inviterId: inviter.author,
    expiresAt: expiresAt ?? DateTime.now().millisecondsSinceEpoch + 60000,
  );
}

void main() {
  group('G-15: метаданные аутентифицированы', () {
    test('подмена genesis в сохранённых метаданных отклоняется', () async {
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
      final groupId = (await lifecycle.createGroup(name: 'Signed')).unwrap();
      final metadata = (await metadataStore.load(groupId)).unwrap()!;
      expect(metadata.isAuthenticated, isTrue);

      final tampered = metadata.withGenesis(EventId('a' * 64));
      await metadataStore.save(tampered);

      final opened = await lifecycle.open(groupId);

      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<GroupMetadataUnavailable>());
    });

    test('неподписанные метаданные не открываются', () async {
      final owner = FakeIdentity(testUserId(1));
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);
      final metadataStore = MemoryGroupMetadataStore();
      const groupId = GroupId('unsigned');
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

      final opened = await lifecycle.open(groupId);

      expect(opened.isErr, isTrue);
      expect(opened.unwrapErr(), isA<GroupMetadataUnavailable>());
    });
  });

  group('G-16: create валидирует draft', () {
    test('owner всегда добавляется в initialMembers', () async {
      final owner = FakeIdentity(testUserId(1));
      final alice = testUserId(2);
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);

      final created = await GroupSyncBridge.create(
        syncEngine: engine,
        groupId: testGroupId,
        name: 'Normalized',
        initialMembers: {alice},
        distributor: InMemoryGroupKeyDistributor(),
        inviteProofVerifier: allowAllProofs,
      );

      expect(created.isOk, isTrue);
      final bridge = created.unwrap();
      addTearDown(bridge.close);
      expect(bridge.state.memberIds, {owner.author, alice});
    });

    test('пустое имя не пишет genesis', () async {
      final owner = FakeIdentity(testUserId(1));
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);

      final created = await GroupSyncBridge.create(
        syncEngine: engine,
        groupId: testGroupId,
        name: '',
        distributor: InMemoryGroupKeyDistributor(),
        inviteProofVerifier: allowAllProofs,
      );

      expect(created.isErr, isTrue);
      expect(await engine.allEvents(testGroupId), isEmpty);
    });

    test('невалидный участник не пишет genesis', () async {
      final owner = FakeIdentity(testUserId(1));
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);

      final created = await GroupSyncBridge.create(
        syncEngine: engine,
        groupId: testGroupId,
        name: 'Bad member',
        initialMembers: {const UserId('not-a-key')},
        distributor: InMemoryGroupKeyDistributor(),
        inviteProofVerifier: allowAllProofs,
      );

      expect(created.isErr, isTrue);
      expect(await engine.allEvents(testGroupId), isEmpty);
    });

    test(
      'lifecycle удаляет pending-метаданные после невалидного draft',
      () async {
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

        final created = await lifecycle.createGroup(name: '');

        expect(created.isErr, isTrue);
        expect((await metadataStore.list()).unwrap(), isEmpty);
        expect((await metadataStore.loadActiveGroup()).unwrap(), isNull);
      },
    );
  });

  group('G-17: ошибки pending изолированы', () {
    test('плохая pending-группа не блокирует recovery и active', () async {
      final owner = FakeIdentity(testUserId(1));
      final attacker = FakeIdentity(testUserId(9));
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

      const badId = GroupId('a-bad');
      final foreign = await signedEventWith(
        identity: attacker,
        draft: GroupCreated(
          id: const EventId(''),
          groupId: badId,
          authorId: attacker.author,
          timestamp: 0,
          name: 'Foreign',
          ownerId: attacker.author,
          initialMembers: {attacker.author},
        ),
        hlc: const Hlc(1, 0),
      );
      expect((await engine.ingest(foreign)).isOk, isTrue);
      await metadataStore.save(
        await signedMetadata(
          const GroupMetadata(
            groupId: badId,
            origin: GroupOrigin.created,
            createdAt: 1,
          ),
          owner,
        ),
      );

      const goodId = GroupId('b-good');
      const codec = GroupEventCodec();
      final payload = codec
          .encode(
            GroupCreated(
              id: const EventId(''),
              groupId: goodId,
              authorId: owner.author,
              timestamp: 0,
              name: 'Good',
              ownerId: owner.author,
              initialMembers: {owner.author},
            ),
          )
          .unwrap();
      final local = await engine.createEvent(
        groupId: goodId,
        kind: SyncEventKind.groupCreated,
        payload: payload,
      );
      await metadataStore.save(
        await signedMetadata(
          const GroupMetadata(
            groupId: goodId,
            origin: GroupOrigin.created,
            createdAt: 2,
          ),
          owner,
        ),
      );
      await metadataStore.saveActiveGroup(goodId);

      final recovered = await lifecycle.recoverPendingGroups();
      expect(recovered.isErr, isTrue);
      expect(recovered.unwrapErr(), isA<GroupRootConflict>());

      final good = (await metadataStore.load(goodId)).unwrap()!;
      expect(good.genesisEventId, local.unwrap().id);
      expect((await metadataStore.load(badId)).unwrap(), isNotNull);

      final active = await lifecycle.loadActiveGroup();
      expect(active.isOk, isTrue);
      expect(active.unwrap(), goodId);
    });
  });

  group('G-18: инвайт аутентифицирован', () {
    test('просроченный инвайт не сохраняется и не активируется', () async {
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
      const groupId = GroupId('expired');
      final link = await inviteFor(
        owner,
        groupId,
        EventId('a' * 64),
        expiresAt: 1,
      );

      final joined = await lifecycle.joinFromInvite(link);

      expect(joined.isErr, isTrue);
      expect(joined.unwrapErr(), isA<GroupInviteRejected>());
      expect((await metadataStore.load(groupId)).unwrap(), isNull);
      expect((await metadataStore.loadActiveGroup()).unwrap(), isNull);
    });

    test('подмена genesis инвайта ломает подпись', () async {
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
      const groupId = GroupId('tampered');
      final link = await inviteFor(owner, groupId, EventId('a' * 64));
      final tampered = InviteLink(
        groupId: link.groupId,
        genesisEventId: EventId('b' * 64),
        inviteId: link.inviteId,
        secret: link.secret,
        inviterId: link.inviterId,
        expiresAt: link.expiresAt,
        signature: link.signature,
      );

      final joined = await lifecycle.joinFromInvite(tampered);

      expect(joined.isErr, isTrue);
      expect(joined.unwrapErr(), isA<GroupInviteRejected>());
      expect((await metadataStore.load(groupId)).unwrap(), isNull);
    });

    test('валидный инвайт сохраняет inviterId, deleteGroup очищает', () async {
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
      const groupId = GroupId('valid');
      final link = await inviteFor(owner, groupId, EventId('a' * 64));

      final joined = await lifecycle.joinFromInvite(link);

      expect(joined.isOk, isTrue);
      final metadata = (await metadataStore.load(groupId)).unwrap()!;
      expect(metadata.inviterId, owner.author);
      expect((await metadataStore.loadActiveGroup()).unwrap(), groupId);

      final deleted = await lifecycle.deleteGroup(groupId);
      expect(deleted.isOk, isTrue);
      expect((await metadataStore.load(groupId)).unwrap(), isNull);
      expect((await metadataStore.loadActiveGroup()).unwrap(), isNull);
    });
  });

  group('G-22: pin до записи genesis', () {
    test('ошибка pin не оставляет genesis в логе', () async {
      final owner = FakeIdentity(testUserId(1));
      final store = MemorySyncEventStore();
      final engine = FailingPinEngine(
        store: store,
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);

      final created = await GroupSyncBridge.create(
        syncEngine: engine,
        groupId: testGroupId,
        name: 'No root',
        distributor: InMemoryGroupKeyDistributor(),
        inviteProofVerifier: allowAllProofs,
      );

      expect(created.isErr, isTrue);
      expect(await engine.allEvents(testGroupId), isEmpty);
      expect(store.length, 0);
    });
  });
}
