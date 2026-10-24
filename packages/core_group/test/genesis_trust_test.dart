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

Future<Harness> createHarness() async {
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
    name: 'Trusted group',
    initialMembers: {owner.author},
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

GroupSyncBridge newBridge(
  Harness harness, {
  required EventId genesisEventId,
  bool allowMissingGenesis = false,
}) {
  return GroupSyncBridge(
    syncEngine: harness.engine,
    controller: GroupController(
      distributor: InMemoryGroupKeyDistributor(),
      expectedGroupId: testGroupId,
      genesisEventId: genesisEventId,
      inviteProofVerifier: allowAllProofs,
    ),
    groupId: testGroupId,
    allowMissingGenesis: allowMissingGenesis,
  );
}

GroupCreated genesisDraft({
  required FakeIdentity author,
  required UserId ownerId,
  String groupId = 'group-1',
  String name = 'Foreign',
}) {
  return GroupCreated(
    id: const EventId(''),
    groupId: GroupId(groupId),
    authorId: author.author,
    timestamp: 0,
    name: name,
    ownerId: ownerId,
    initialMembers: {ownerId},
  );
}

void main() {
  group('доверенный genesis в GroupSyncBridge', () {
    test('restore применяет только сохранённый genesis', () async {
      final harness = await createHarness();
      addTearDown(harness.engine.close);
      final genesisId = harness.bridge.genesisEventId;
      await harness.bridge.close();

      final restored = newBridge(harness, genesisEventId: genesisId);
      addTearDown(restored.close);

      final started = await restored.start();

      expect(started.isOk, isTrue);
      expect(restored.state.name, 'Trusted group');
      expect(restored.state.ownerId, harness.owner.author);
    });

    test('restore без genesis fail-closed', () async {
      final owner = FakeIdentity(testUserId(1));
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);
      final bridge = GroupSyncBridge(
        syncEngine: engine,
        controller: GroupController(
          distributor: InMemoryGroupKeyDistributor(),
          expectedGroupId: testGroupId,
          genesisEventId: const EventId('missing'),
          inviteProofVerifier: allowAllProofs,
        ),
        groupId: testGroupId,
      );
      addTearDown(bridge.close);

      final started = await bridge.start();

      expect(started.isErr, isTrue);
      expect(started.unwrapErr(), isA<GenesisMissing>());
      expect(bridge.state.memberIds, isEmpty);
    });

    test(
      'чужой GroupCreated даёт GenesisConflict, а не выбор по HLC',
      () async {
        final harness = await createHarness();
        addTearDown(harness.engine.close);
        final genesisId = harness.bridge.genesisEventId;
        await harness.bridge.close();

        final foreign = await signedEventWith(
          identity: harness.owner,
          draft: genesisDraft(
            author: harness.owner,
            ownerId: harness.owner.author,
            name: 'Backdated',
          ),
          hlc: const Hlc(1, 0),
        );
        expect((await harness.engine.ingest(foreign)).isOk, isTrue);

        final restored = newBridge(harness, genesisEventId: genesisId);
        addTearDown(restored.close);

        final started = await restored.start();

        expect(started.isErr, isTrue);
        expect(started.unwrapErr(), isA<GenesisConflict>());
        expect(restored.state.memberIds, isEmpty);
      },
    );

    test('genesis с чужим автором отклоняется', () async {
      final owner = FakeIdentity(testUserId(1));
      final alice = FakeIdentity(testUserId(2));
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);
      final forged = await signedEventWith(
        identity: alice,
        draft: genesisDraft(author: alice, ownerId: owner.author),
        hlc: const Hlc(1, 0),
      );
      expect((await engine.ingest(forged)).isOk, isTrue);

      final bridge = GroupSyncBridge(
        syncEngine: engine,
        controller: GroupController(
          distributor: InMemoryGroupKeyDistributor(),
          expectedGroupId: testGroupId,
          genesisEventId: forged.id,
        ),
        groupId: testGroupId,
      );
      addTearDown(bridge.close);

      final started = await bridge.start();

      expect(started.isErr, isTrue);
      expect(started.unwrapErr(), isA<InvalidGenesis>());
      expect(bridge.state.memberIds, isEmpty);
    });

    test('подпись genesis проверяется при restore', () async {
      final harness = await createHarness();
      addTearDown(harness.engine.close);
      final genesis = (await harness.engine.allEvents(testGroupId))
          .firstWhere((event) => event.kind == SyncEventKind.groupCreated);
      await harness.bridge.close();

      final tamperedStore = MemorySyncEventStore();
      await tamperedStore.write(genesis.copyWith(signature: 'bad').toRecord());
      final engine = SyncEngineImpl(
        store: tamperedStore,
        signer: harness.owner.signer,
        localAuthor: harness.owner.author,
      );
      addTearDown(engine.close);
      final bridge = GroupSyncBridge(
        syncEngine: engine,
        controller: GroupController(
          distributor: InMemoryGroupKeyDistributor(),
          expectedGroupId: testGroupId,
          genesisEventId: genesis.id,
        ),
        groupId: testGroupId,
      );
      addTearDown(bridge.close);

      final started = await bridge.start();

      expect(started.isErr, isTrue);
      expect(started.unwrapErr(), isA<InvalidGenesis>());
      expect(bridge.state.memberIds, isEmpty);
    });

    test('invite-путь ждёт genesis и применяет его после sync', () async {
      final owner = FakeIdentity(testUserId(1));
      final store = MemorySyncEventStore();
      final engine = SyncEngineImpl(
        store: store,
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);
      final genesis = await signedEventWith(
        identity: owner,
        draft: genesisDraft(
          author: owner,
          ownerId: owner.author,
          name: 'Invited',
        ),
        hlc: const Hlc(1, 0),
      );
      final bridge = GroupSyncBridge(
        syncEngine: engine,
        controller: GroupController(
          distributor: InMemoryGroupKeyDistributor(),
          expectedGroupId: testGroupId,
          genesisEventId: genesis.id,
          inviteProofVerifier: allowAllProofs,
        ),
        groupId: testGroupId,
        allowMissingGenesis: true,
      );
      addTearDown(bridge.close);

      final started = await bridge.start();
      expect(started.isOk, isTrue);
      expect(bridge.state.memberIds, isEmpty);

      final updated = bridge.watch().first;
      expect((await engine.ingest(genesis)).isOk, isTrue);
      await updated.timeout(const Duration(seconds: 2));

      expect(bridge.state.name, 'Invited');
      expect(bridge.state.memberIds, {owner.author});
    });
  });
}
