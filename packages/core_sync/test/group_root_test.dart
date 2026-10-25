import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/memory_store.dart';
import 'support/test_signer.dart';

void main() {
  group('SyncEngineImpl / доверенный корень группы', () {
    late MemorySyncEventStore store;
    late SyncEngineImpl engine;
    late UserId owner;
    late TestSigner ownerSigner;
    late UserId attacker;
    late TestSigner attackerSigner;
    const group = GroupId('g');

    setUp(() {
      store = MemorySyncEventStore();
      owner = testAuthor(0);
      ownerSigner = TestSigner(owner.value);
      attacker = testAuthor(1);
      attackerSigner = TestSigner(attacker.value);
      engine = SyncEngineImpl(
        store: store,
        signer: ownerSigner,
        localAuthor: owner,
      );
    });

    tearDown(() async {
      await engine.close();
    });

    Future<SyncEvent> root({
      required TestSigner signer,
      required UserId author,
    }) {
      return signedEvent(
        signer: signer,
        author: author,
        groupId: group,
        hlc: const Hlc(1000, 0),
        kind: SyncEventKind.groupCreated,
        payload: Uint8List(0),
      );
    }

    test('чужой groupCreated после pin отклоняется', () async {
      final expected = await root(signer: ownerSigner, author: owner);
      expect((await engine.pinGroupRoot(group, expected.id)).isOk, isTrue);

      final foreign = await root(signer: attackerSigner, author: attacker);
      final rejected = await engine.ingest(foreign);

      expect(rejected.isErr, isTrue);
      expect(rejected.unwrapErr(), isA<ForeignGroupRoot>());
      expect(await engine.allEvents(group), isEmpty);
      expect(store.length, 0);
    });

    test('доверенный groupCreated принимается после pin', () async {
      final expected = await root(signer: ownerSigner, author: owner);
      expect((await engine.pinGroupRoot(group, expected.id)).isOk, isTrue);

      final accepted = await engine.ingest(expected);

      expect(accepted.isOk, isTrue);
      expect(accepted.unwrap().outcome, IngestOutcome.inserted);
      expect(await engine.allEvents(group), hasLength(1));
    });

    test('повторный pin с другим корнем отклоняется', () async {
      final expected = await root(signer: ownerSigner, author: owner);
      final foreign = await root(signer: attackerSigner, author: attacker);
      expect((await engine.pinGroupRoot(group, expected.id)).isOk, isTrue);

      final conflict = await engine.pinGroupRoot(group, foreign.id);

      expect(conflict.isErr, isTrue);
      expect(conflict.unwrapErr(), isA<ForeignGroupRoot>());
    });

    test('чужой корень из хранилища не попадает в индекс после pin', () async {
      final expected = await root(signer: ownerSigner, author: owner);
      final foreign = await root(signer: attackerSigner, author: attacker);
      await store.write(foreign.toRecord());

      expect((await engine.pinGroupRoot(group, expected.id)).isOk, isTrue);
      await engine.registerGroup(group);

      expect(await engine.allEvents(group), isEmpty);
    });

    test('чужой корень удаляется из индекса при pin после загрузки', () async {
      final expected = await root(signer: ownerSigner, author: owner);
      final foreign = await root(signer: attackerSigner, author: attacker);
      expect((await engine.ingest(foreign)).isOk, isTrue);
      expect(await engine.allEvents(group), hasLength(1));

      expect((await engine.pinGroupRoot(group, expected.id)).isOk, isTrue);

      expect(await engine.allEvents(group), isEmpty);
    });

    test('незакреплённая группа ограничена по числу событий', () async {
      final limited = SyncEngineImpl(
        store: store,
        signer: ownerSigner,
        localAuthor: owner,
        maxUnpinnedGroupEvents: 2,
      );
      addTearDown(limited.close);
      final foreign = await root(signer: attackerSigner, author: attacker);
      expect((await limited.ingest(foreign)).isOk, isTrue);
      final added = await signedEvent(
        signer: attackerSigner,
        author: attacker,
        groupId: group,
        hlc: const Hlc(1001, 0),
        kind: SyncEventKind.memberAdded,
        targetId: attacker.value,
      );
      expect((await limited.ingest(added)).isOk, isTrue);
      final blocked = await signedEvent(
        signer: attackerSigner,
        author: attacker,
        groupId: group,
        hlc: const Hlc(1002, 0),
        kind: SyncEventKind.messageCreated,
        payload: Uint8List(0),
      );
      final rejected = await limited.ingest(blocked);
      expect(rejected.isErr, isTrue);
      expect(rejected.unwrapErr(), isA<UnpinnedGroupQuarantine>());

      final expected = await root(signer: ownerSigner, author: owner);
      expect((await limited.pinGroupRoot(group, expected.id)).isOk, isTrue);
      expect((await limited.ingest(expected)).isOk, isTrue);
      final ownerMessage = await signedEvent(
        signer: ownerSigner,
        author: owner,
        groupId: group,
        hlc: const Hlc(1003, 0),
        kind: SyncEventKind.messageCreated,
        payload: Uint8List(0),
      );
      final accepted = await limited.ingest(ownerMessage);
      expect(accepted.isOk, isTrue);
      expect(accepted.unwrap().outcome, IngestOutcome.inserted);
    });

    test('потомки чужого корня не переживают pin', () async {
      final expected = await root(signer: ownerSigner, author: owner);
      final foreign = await root(signer: attackerSigner, author: attacker);
      expect((await engine.ingest(foreign)).isOk, isTrue);
      final added = await signedEvent(
        signer: attackerSigner,
        author: attacker,
        groupId: group,
        hlc: const Hlc(1001, 0),
        kind: SyncEventKind.memberAdded,
        targetId: attacker.value,
      );
      expect((await engine.ingest(added)).isOk, isTrue);
      expect(await engine.allEvents(group), hasLength(2));

      expect((await engine.pinGroupRoot(group, expected.id)).isOk, isTrue);

      expect(await engine.allEvents(group), isEmpty);
      final message = await signedEvent(
        signer: attackerSigner,
        author: attacker,
        groupId: group,
        hlc: const Hlc(1002, 0),
        kind: SyncEventKind.messageCreated,
        payload: Uint8List(0),
      );
      final result = await engine.ingest(message);
      expect(result.isOk, isTrue);
      expect(result.unwrap().outcome, IngestOutcome.pending);
    });
  });
}
