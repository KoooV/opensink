import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/memory_store.dart';
import 'support/test_signer.dart';

void main() {
  group('SyncIngestPipeline / engine receive path', () {
    late MemorySyncEventStore store;
    late HlcClock clock;
    late SyncEngineImpl engine;
    late UserId owner;
    late TestSigner ownerSigner;
    late UserId member;
    late TestSigner memberSigner;
    const group = GroupId('g');
    const channel = ChannelId('c');
    var now = 1000;

    setUp(() async {
      store = MemorySyncEventStore();
      now = 1000;
      clock = HlcClock(nowMs: () => now);
      owner = testAuthor(0);
      ownerSigner = TestSigner(owner.value);
      member = testAuthor(1);
      memberSigner = TestSigner(member.value);
      engine = SyncEngineImpl(
        store: store,
        signer: ownerSigner,
        localAuthor: owner,
        clock: clock,
      );
      await engine.registerGroup(group);
      expect((await engine.createGroup(group)).isOk, isTrue);
    });

    tearDown(() async {
      await engine.close();
    });

    test('valid event from owner is inserted once', () async {
      final created = await engine.postMessage(group, channel, 'hello');
      expect(created.isOk, isTrue);

      final duplicate = await engine.ingest(created.unwrap());
      expect(duplicate.unwrap().outcome, IngestOutcome.duplicate);
      expect(store.length, 2);
    });

    test('bad signature is rejected before membership and write', () async {
      now = 2000;
      final event = await signedEvent(
        signer: ownerSigner,
        author: member,
        groupId: group,
        hlc: Hlc(now, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: Uint8List.fromList(utf8.encode('forged')),
      );
      final result = await engine.ingest(event);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidSignature>());
      expect(store.length, 1);
    });

    test('id mismatch is rejected before signature', () async {
      final created = (await engine.postMessage(group, channel, 'x')).unwrap();
      final forged = created.copyWith(id: const EventId('deadbeef'));
      final result = await engine.ingest(forged);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<EventIdMismatch>());
    });

    test('oversized event is rejected before signature', () async {
      final huge = Uint8List(maxSyncEventBytes + 1);
      final event = await signedEvent(
        signer: ownerSigner,
        author: owner,
        groupId: group,
        hlc: Hlc(now, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: huge,
      );
      final result = await engine.ingest(event);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<EventTooLarge>());
    });

    test('author must be a member at event time', () async {
      now = 2000;
      await engine.addMember(group, member);
      now = 3000;
      final event = await signedEvent(
        signer: memberSigner,
        author: member,
        groupId: group,
        hlc: Hlc(engine.lastHlc.physicalMs + 1, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: Uint8List.fromList(utf8.encode('from member')),
      );
      final accepted = await engine.ingest(event);
      expect(accepted.isOk, isTrue);
      expect(accepted.unwrap().outcome, IngestOutcome.inserted);

      now = 4000;
      await engine.removeMember(group, member);
      final afterRemoval = await signedEvent(
        signer: memberSigner,
        author: member,
        groupId: group,
        hlc: Hlc(engine.lastHlc.physicalMs + 1, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: Uint8List.fromList(utf8.encode('after removal')),
      );
      final rejected = await engine.ingest(afterRemoval);
      expect(rejected.isErr, isTrue);
      expect(rejected.unwrapErr(), isA<NotAMember>());
    });

    test('unknown author is pending until membership arrives', () async {
      final futureMember = testAuthor(2);
      final futureSigner = TestSigner(futureMember.value);
      final pendingEvent = await signedEvent(
        signer: futureSigner,
        author: futureMember,
        groupId: group,
        hlc: Hlc(engine.lastHlc.physicalMs + 10, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: Uint8List.fromList(utf8.encode('early')),
      );
      final pending = await engine.ingest(pendingEvent);
      expect(pending.unwrap().outcome, IngestOutcome.pending);
      expect(store.length, 1);

      await engine.addMember(group, futureMember);
      final events = await engine.allEvents(group);
      expect(
        events.map((event) => event.id.value),
        contains(pendingEvent.id.value),
      );
      expect(store.length, 3);
    });

    test('local events form a per-author hash chain', () async {
      final first = (await engine.postMessage(group, channel, 'one')).unwrap();
      final second = (await engine.postMessage(group, channel, 'two')).unwrap();
      expect(first.prevId, isNotNull);
      expect(second.prevId, first.id);
    });

    test('prev from another author is rejected when known', () async {
      now = 2000;
      await engine.addMember(group, member);
      final memberEvent = await signedEvent(
        signer: memberSigner,
        author: member,
        groupId: group,
        hlc: Hlc(engine.lastHlc.physicalMs + 1, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: Uint8List.fromList(utf8.encode('member')),
      );
      expect((await engine.ingest(memberEvent)).isOk, isTrue);

      final forged = await signedEvent(
        signer: ownerSigner,
        author: owner,
        groupId: group,
        hlc: Hlc(engine.lastHlc.physicalMs + 1, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        prevId: memberEvent.id,
        payload: Uint8List.fromList(utf8.encode('wrong prev')),
      );
      final result = await engine.ingest(forged);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidPrev>());
    });


    test('event too far in the future is rejected', () async {
      final future = DateTime.now().millisecondsSinceEpoch + 31000;
      final event = await signedEvent(
        signer: ownerSigner,
        author: owner,
        groupId: group,
        hlc: Hlc(future, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: Uint8List.fromList(utf8.encode('future')),
      );
      final result = await engine.ingest(event);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<HlcTooFarInFuture>());
    });

    test('duplicate delivered through gossip is deduplicated', () async {
      final first = (await engine.postMessage(group, channel, 'one')).unwrap();
      final second = (await engine.postMessage(group, channel, 'two')).unwrap();
      await engine.ingest(first);
      await engine.ingest(second);
      expect((await engine.projection(group)).messages.length, 2);
      expect(store.length, 3);
    });
  });
}
