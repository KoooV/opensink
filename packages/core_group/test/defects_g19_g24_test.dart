import 'dart:async';

import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/fake_sync.dart';
import 'support/fixtures.dart';

class StaticEventsEngine extends SyncEngineImpl {
  StaticEventsEngine({
    required super.store,
    required super.signer,
    required super.localAuthor,
    required this.events,
  });

  final List<SyncEvent> events;

  @override
  Future<List<SyncEvent>> allEvents(GroupId groupId) async => events;
}

class LateEventEngine extends SyncEngineImpl {
  LateEventEngine({
    required super.store,
    required super.signer,
    required super.localAuthor,
    required this.firstEvents,
    required this.laterEvents,
  });

  final List<SyncEvent> firstEvents;
  final List<SyncEvent> laterEvents;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  var _calls = 0;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<SyncEvent>> allEvents(GroupId groupId) async {
    _calls++;
    if (_calls == 1) {
      scheduleMicrotask(() => _changes.add(null));
      return firstEvents;
    }
    return laterEvents;
  }

  @override
  Future<void> close() async {
    await _changes.close();
    await super.close();
  }
}

class RecordingCodec extends GroupEventCodec {
  RecordingCodec();

  final List<String> decoded = <String>[];

  @override
  Result<GroupEvent, GroupSyncError> decode(SyncEvent event) {
    decoded.add(event.id.value);
    return super.decode(event);
  }
}

Future<SyncEvent> genesisFor(
  FakeIdentity owner,
  SyncEngineImpl engine,
  GroupId groupId,
) async {
  final created = await GroupSyncBridge.create(
    syncEngine: engine,
    groupId: groupId,
    name: 'Race group',
    initialMembers: {owner.author},
    distributor: InMemoryGroupKeyDistributor(),
    inviteProofVerifier: allowAllProofs,
  );
  final bridge = created.unwrap();
  final genesis = (await engine.allEvents(groupId))
      .firstWhere((event) => event.kind == SyncEventKind.groupCreated);
  await bridge.close();
  return genesis;
}

void main() {
  test('G-19: событие между первым refresh и подпиской не теряется', () async {
    final owner = FakeIdentity(testUserId(1));
    final alice = testUserId(2);
    final source = SyncEngineImpl(
      store: MemorySyncEventStore(),
      signer: owner.signer,
      localAuthor: owner.author,
    );
    addTearDown(source.close);
    const groupId = GroupId('race-group');
    final genesis = await genesisFor(owner, source, groupId);
    final added = await signedEventWith(
      identity: owner,
      draft: MemberAdded(
        id: const EventId(''),
        groupId: groupId,
        authorId: owner.author,
        timestamp: 0,
        prevId: genesis.id,
        userId: alice,
      ),
      hlc: Hlc(genesis.hlc.physicalMs + 1, 0),
    );

    final engine = LateEventEngine(
      store: MemorySyncEventStore(),
      signer: owner.signer,
      localAuthor: owner.author,
      firstEvents: [genesis],
      laterEvents: [genesis, added],
    );
    addTearDown(engine.close);
    final bridge = GroupSyncBridge(
      syncEngine: engine,
      controller: GroupController(
        distributor: InMemoryGroupKeyDistributor(),
        expectedGroupId: groupId,
        genesisEventId: genesis.id,
        inviteProofVerifier: allowAllProofs,
      ),
      groupId: groupId,
      requireLocalAuthor: true,
    );
    addTearDown(bridge.close);
    final appeared = bridge.watch().firstWhere(
      (state) => state.memberIds.contains(alice),
    );

    final started = await bridge.start();

    expect(started.isOk, isTrue);
    await appeared.timeout(const Duration(seconds: 2));
    expect(bridge.state.memberIds, contains(alice));
  });

  test(
    'G-20: недоверенное событие не декодируется до проверки подписи',
    () async {
      final owner = FakeIdentity(testUserId(1));
      final source = SyncEngineImpl(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
      );
      addTearDown(source.close);
      const groupId = GroupId('decode-order');
      final genesis = await genesisFor(owner, source, groupId);
      final valid = await signedEventWith(
        identity: owner,
        draft: MemberAdded(
          id: const EventId(''),
          groupId: groupId,
          authorId: owner.author,
          timestamp: 0,
          prevId: genesis.id,
          userId: testUserId(2),
        ),
        hlc: Hlc(genesis.hlc.physicalMs + 1, 0),
      );
      final tampered = valid.copyWith(signature: 'bad');

      final engine = StaticEventsEngine(
        store: MemorySyncEventStore(),
        signer: owner.signer,
        localAuthor: owner.author,
        events: [genesis, tampered],
      );
      addTearDown(engine.close);
      final codec = RecordingCodec();
      final bridge = GroupSyncBridge(
        syncEngine: engine,
        controller: GroupController(
          distributor: InMemoryGroupKeyDistributor(),
          expectedGroupId: groupId,
          genesisEventId: genesis.id,
          inviteProofVerifier: allowAllProofs,
        ),
        groupId: groupId,
        codec: codec,
        requireLocalAuthor: true,
      );
      addTearDown(bridge.close);

      final started = await bridge.start();

      expect(started.isOk, isTrue);
      expect(codec.decoded, contains(genesis.id.value));
      expect(codec.decoded, isNot(contains(tampered.id.value)));
    },
  );
}
