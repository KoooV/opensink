import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/memory_store.dart';
import 'support/test_signer.dart';

void main() {
  group('SyncIngestPipeline / ingress rate limit', () {
    test('limits events per author and resets after the window', () async {
      final store = MemorySyncEventStore();
      final author = testAuthor(0);
      final signer = TestSigner(author.value);
      const group = GroupId('g');
      const channel = ChannelId('c');
      var now = 1000;

      final pipeline = SyncIngestPipeline(
        store: store,
        signer: signer,
        membershipCheck: (_) => MembershipStatus.member,
        nowMs: () => now,
        maxEventsPerAuthorPerWindow: 2,
        authorRateWindow: const Duration(seconds: 10),
      );

      Future<SyncEvent> event(String text) {
        now += 1;
        return signedEvent(
          signer: signer,
          author: author,
          groupId: group,
          hlc: Hlc(now, 0),
          kind: SyncEventKind.messageCreated,
          channelId: channel,
          payload: Uint8List.fromList(utf8.encode(text)),
        );
      }

      expect((await pipeline.ingest(await event('one'))).isOk, isTrue);
      expect((await pipeline.ingest(await event('two'))).isOk, isTrue);

      final overRate = await pipeline.ingest(await event('three'));
      expect(overRate.isErr, isTrue);
      expect(overRate.unwrapErr(), isA<AuthorRateLimited>());
      expect(store.length, 2);

      now += 10000;
      final afterWindow = await pipeline.ingest(await event('four'));
      expect(afterWindow.isOk, isTrue);
      expect(store.length, 3);
    });

    test('pending retries are not throttled again', () async {
      final store = MemorySyncEventStore();
      final author = testAuthor(0);
      final signer = TestSigner(author.value);
      const group = GroupId('g');
      const channel = ChannelId('c');
      var now = 1000;

      final pipeline = SyncIngestPipeline(
        store: store,
        signer: signer,
        membershipCheck: (_) => MembershipStatus.member,
        nowMs: () => now,
        maxEventsPerAuthorPerWindow: 1,
        authorRateWindow: const Duration(seconds: 10),
      );

      final event = await signedEvent(
        signer: signer,
        author: author,
        groupId: group,
        hlc: Hlc(now, 0),
        kind: SyncEventKind.messageCreated,
        channelId: channel,
        payload: Uint8List.fromList(utf8.encode('retry')),
      );

      expect((await pipeline.ingest(event)).isOk, isTrue);
      final retry = await pipeline.ingest(event, enforceRate: false);
      expect(retry.isOk, isTrue);
      expect(retry.unwrap().outcome, IngestOutcome.duplicate);
    });
  });
}
