import 'dart:async';

import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/fake_sync.dart';
import 'support/fixtures.dart';

class BlockingPinEngine extends SyncEngineImpl {
  BlockingPinEngine({
    required super.store,
    required super.signer,
    required super.localAuthor,
  });

  final Completer<void> _pinGate = Completer<void>();

  void releasePin() {
    if (!_pinGate.isCompleted) _pinGate.complete();
  }

  @override
  Future<Result<void, SyncError>> pinGroupRoot(
    GroupId groupId,
    EventId genesisEventId,
  ) async {
    await _pinGate.future;
    return super.pinGroupRoot(groupId, genesisEventId);
  }
}

class ThrowingEngine extends SyncEngineImpl {
  ThrowingEngine({
    required super.store,
    required super.signer,
    required super.localAuthor,
  });

  bool failOnce = true;

  @override
  Future<List<SyncEvent>> allEvents(GroupId groupId) {
    if (failOnce) {
      failOnce = false;
      throw StateError('boom');
    }
    return super.allEvents(groupId);
  }
}

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

    test('чужой GroupCreated в хранилище не блокирует restore', () async {
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
      await harness.store.write(foreign.toRecord());

      final engine = SyncEngineImpl(
        store: harness.store,
        signer: harness.owner.signer,
        localAuthor: harness.owner.author,
      );
      addTearDown(engine.close);
      final restored = GroupSyncBridge(
        syncEngine: engine,
        controller: GroupController(
          distributor: InMemoryGroupKeyDistributor(),
          expectedGroupId: testGroupId,
          genesisEventId: genesisId,
          inviteProofVerifier: allowAllProofs,
        ),
        groupId: testGroupId,
      );
      addTearDown(restored.close);

      final started = await restored.start();

      expect(started.isOk, isTrue);
      expect(restored.fatalError, isNull);
      expect(restored.state.name, 'Trusted group');
      expect(restored.state.memberIds, {harness.owner.author});
      expect(
        (await engine.allEvents(testGroupId))
            .where((event) => event.kind == SyncEventKind.groupCreated),
        hasLength(1),
      );
    });

    test(
      'чужой genesis после старта отклоняется, группа продолжает работу',
      () async {
        final harness = await createHarness();
        addTearDown(harness.bridge.close);
        addTearDown(harness.engine.close);

        final attacker = FakeIdentity(testUserId(9));
        final foreign = await signedEventWith(
          identity: attacker,
          draft: genesisDraft(
            author: attacker,
            ownerId: attacker.author,
            groupId: testGroupId.value,
          ),
          hlc: Hlc(harness.engine.lastHlc.physicalMs + 1, 0),
        );

        final rejected = await harness.engine.ingest(foreign);

        expect(rejected.isErr, isTrue);
        expect(rejected.unwrapErr(), isA<ForeignGroupRoot>());
        expect(harness.bridge.fatalError, isNull);

        final renamed = await harness.bridge.publish(
          GroupRenamed(
            id: const EventId(''),
            groupId: testGroupId,
            authorId: harness.owner.author,
            timestamp: 0,
            prevId: harness.bridge.nextPrevId,
            name: 'Still working',
          ),
        );
        expect(renamed.isOk, isTrue);
        expect(harness.bridge.state.name, 'Still working');
      },
    );

    test('publish до start отклоняется и не пишет в лог', () async {
      final owner = FakeIdentity(testUserId(1));
      final engine = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(engine.close);
      final genesis = await signedEventWith(
        identity: owner,
        draft: genesisDraft(
          author: owner,
          ownerId: owner.author,
          groupId: testGroupId.value,
        ),
        hlc: const Hlc(1, 0),
      );
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

      final before = await engine.allEvents(testGroupId);
      final result = await bridge.publish(
        GroupRenamed(
          id: const EventId(''),
          groupId: testGroupId,
          authorId: owner.author,
          timestamp: 0,
          name: 'Too early',
        ),
      );

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<MalformedGroupEvent>());
      expect(await engine.allEvents(testGroupId), hasLength(before.length));
    });

    test('параллельный start не возвращает Ok до валидации', () async {
      final harness = await createHarness();
      addTearDown(harness.engine.close);
      final genesisId = harness.bridge.genesisEventId;
      await harness.bridge.close();

      final engine = BlockingPinEngine(
        store: harness.store,
        signer: harness.owner.signer,
        localAuthor: harness.owner.author,
      );
      addTearDown(engine.close);
      final bridge = GroupSyncBridge(
        syncEngine: engine,
        controller: GroupController(
          distributor: InMemoryGroupKeyDistributor(),
          expectedGroupId: testGroupId,
          genesisEventId: genesisId,
        ),
        groupId: testGroupId,
      );
      addTearDown(bridge.close);

      final first = bridge.start();
      final second = bridge.start();
      var secondDone = false;
      unawaited(
        second.then((_) {
          secondDone = true;
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(secondDone, isFalse);
      final earlyPublish = await bridge.publish(
        GroupRenamed(
          id: const EventId(''),
          groupId: testGroupId,
          authorId: harness.owner.author,
          timestamp: 0,
          name: 'Too early',
        ),
      );
      expect(earlyPublish.isErr, isTrue);

      engine.releasePin();
      expect((await first).isOk, isTrue);
      expect((await second).isOk, isTrue);
      expect(bridge.state.name, 'Trusted group');
    });

    test(
      'исключение в start не оставляет мост started и повторяется',
      () async {
        final harness = await createHarness();
        addTearDown(harness.engine.close);
        final genesisId = harness.bridge.genesisEventId;
        await harness.bridge.close();

        final engine = ThrowingEngine(
          store: harness.store,
          signer: harness.owner.signer,
          localAuthor: harness.owner.author,
        );
        addTearDown(engine.close);
        final bridge = GroupSyncBridge(
          syncEngine: engine,
          controller: GroupController(
            distributor: InMemoryGroupKeyDistributor(),
            expectedGroupId: testGroupId,
            genesisEventId: genesisId,
          ),
          groupId: testGroupId,
        );
        addTearDown(bridge.close);

        final failed = await bridge.start();
        expect(failed.isErr, isTrue);
        expect(failed.unwrapErr(), isA<SyncEngineFailure>());

        final retried = await bridge.start();
        expect(retried.isOk, isTrue);
        expect(bridge.state.name, 'Trusted group');
      },
    );

    test('publish после фатальной ошибки возвращает её и не пишет', () async {
      final owner = FakeIdentity(testUserId(1));
      final genesisStore = MemorySyncEventStore();
      final goodEngine = SyncEngineImpl(
        store: genesisStore,
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(goodEngine.close);
      final created = await GroupSyncBridge.create(
        syncEngine: goodEngine,
        groupId: testGroupId,
        name: 'Broken',
        distributor: InMemoryGroupKeyDistributor(),
      );
      final good = created.unwrap();
      addTearDown(good.close);
      final genesis = (await goodEngine.allEvents(testGroupId))
          .firstWhere((event) => event.kind == SyncEventKind.groupCreated);
      await good.close();

      final tamperedStore = MemorySyncEventStore();
      await tamperedStore.write(genesis.copyWith(signature: 'bad').toRecord());
      final engine = SyncEngineImpl(
        store: tamperedStore,
        signer: owner.signer,
        localAuthor: owner.author,
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
      expect(started.unwrapErr(), isA<GenesisMissing>());

      final result = await bridge.publish(
        GroupRenamed(
          id: const EventId(''),
          groupId: testGroupId,
          authorId: owner.author,
          timestamp: 0,
          name: 'Blocked',
        ),
      );

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<GenesisMissing>());
      expect(await engine.allEvents(testGroupId), isEmpty);
    });

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
      expect(started.unwrapErr(), isA<GenesisMissing>());
      expect(bridge.state.memberIds, isEmpty);
    });

    test('invite publish до появления genesis отклоняется', () async {
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
          genesisEventId: const EventId('pending-root'),
        ),
        groupId: testGroupId,
        allowMissingGenesis: true,
      );
      addTearDown(bridge.close);

      final started = await bridge.start();
      expect(started.isOk, isTrue);

      final result = await bridge.publish(
        GroupRenamed(
          id: const EventId(''),
          groupId: testGroupId,
          authorId: owner.author,
          timestamp: 0,
          name: 'Before root',
        ),
      );

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<MalformedGroupEvent>());
      expect(await engine.allEvents(testGroupId), isEmpty);
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
