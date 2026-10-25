import 'dart:math';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/ed25519_identity.dart';
import 'support/memory_store.dart';

const _group = GroupId('layer10-group');
const _channel = ChannelId('general');

Future<
  ({Ed25519Identity identity, SyncEngineImpl engine, ChatServiceImpl chat})
>
_replica(int index, int Function() nowMs) async {
  final identity = await Ed25519Identity.create(index);
  final engine = SyncEngineImpl(
    store: MemorySyncEventStore(),
    signer: identity.signer,
    localAuthor: identity.author,
    nowMs: nowMs,
  );
  final chat = ChatServiceImpl(
    engine: engine,
    localUser: identity.author,
    nowMs: nowMs,
  );
  return (identity: identity, engine: engine, chat: chat);
}

Future<void> _syncAll(List<SyncEngineImpl> engines) async {
  for (var pass = 0; pass < 3; pass++) {
    for (final target in engines) {
      for (final source in engines) {
        if (identical(target, source)) continue;
        for (final event in await source.allEvents(_group)) {
          await target.ingest(event);
        }
      }
    }
  }
}

Future<void> _setUpGroup(List<SyncEngineImpl> engines) async {
  await engines.first.createGroup(_group);
  for (final engine in engines.skip(1)) {
    await engines.first.addMember(_group, engine.localAuthor);
  }
  await _syncAll(engines);
}

void main() {
  test(
    '1. three peers converge on chat, edit, delete, reactions and markers',
    () async {
      var now = 1000;
      int clock() => now++;
      final a = await _replica(0, clock);
      final b = await _replica(1, clock);
      final c = await _replica(2, clock);
      final engines = [a.engine, b.engine, c.engine];
      await _setUpGroup(engines);

      final sent = await a.chat.send(
        _group,
        _channel,
        'hello @b',
        mentions: [b.identity.author],
      );
      await _syncAll(engines);
      expect(sent.isOk, isTrue);

      final reply = await b.chat.reply(
        _group,
        _channel,
        sent.unwrap().id,
        'hi a',
      );
      expect(reply.isOk, isTrue);
      await _syncAll(engines);

      expect(
        (await a.chat.edit(
          _group,
          _channel,
          sent.unwrap().id,
          'hello edited',
        )).isOk,
        isTrue,
      );
      await _syncAll(engines);

      expect(
        (await b.chat.setReaction(
          _group,
          _channel,
          sent.unwrap().id,
          ':+1:',
        )).isOk,
        isTrue,
      );
      await _syncAll(engines);

      expect(
        (await c.chat.markRead(_group, _channel, reply.unwrap().id)).isOk,
        isTrue,
      );
      await _syncAll(engines);

      expect(
        (await a.chat.delete(_group, _channel, sent.unwrap().id)).isOk,
        isTrue,
      );
      await _syncAll(engines);

      final views = <ChatView>[
        await a.chat.view(_group, _channel),
        await b.chat.view(_group, _channel),
        await c.chat.view(_group, _channel),
      ];
      for (final view in views) {
        expect(view.messages, hasLength(2));
        final first = view.messages.first;
        expect(first.deleted, isTrue);
        expect(first.content, isEmpty);
        expect(first.reactions[':+1:'], contains(b.identity.author.value));
        final second = view.messages.last;
        expect(second.replyTo, sent.unwrap().id);
        expect(
          view.readMarkers[c.identity.author.value]?.messageId,
          reply.unwrap().id,
        );
      }

      final events = await a.engine.allEvents(_group);
      final shuffled = List<SyncEvent>.from(events)..shuffle(Random(7));
      final projection = ChatProjection.fromEvents(shuffled);
      expect(projection.messages, hasLength(2));
      expect(projection.messages[sent.unwrap().id]!.deleted, isTrue);

      final beforeTyping = (await a.engine.allEvents(_group)).length;
      await a.chat.setTyping(_group, _channel, true);
      expect((await a.engine.allEvents(_group)).length, beforeTyping);

      await a.chat.close();
      await b.chat.close();
      await c.chat.close();
    },
  );

  test(
    '2. only the author can edit or delete; remote forgery is ignored',
    () async {
      var now = 1000;
      final a = await _replica(0, () => now++);
      final b = await _replica(1, () => now++);
      final engines = [a.engine, b.engine];
      await _setUpGroup(engines);

      final sent = (await a.chat.send(_group, _channel, 'mine')).unwrap();
      await _syncAll(engines);

      expect(
        await b.chat.edit(_group, _channel, sent.id, 'hijack'),
        isA<Err>(),
      );
      expect(await b.chat.delete(_group, _channel, sent.id), isA<Err>());

      await b.engine.editMessage(_group, _channel, EventId(sent.id), 'hijack');
      await _syncAll(engines);
      final view = await a.chat.view(_group, _channel);
      expect(view.messages.single.content, 'mine');

      await a.chat.close();
      await b.chat.close();
    },
  );

  test('3. presence and typing are ephemeral with TTL', () async {
    var now = 5000;
    final local = (await Ed25519Identity.create(0)).author;
    final remote = (await Ed25519Identity.create(1)).author;
    final bus = FakeEphemeralChatBus();
    final service = PresenceServiceImpl(
      bus: bus,
      localUser: local,
      nowMs: () => now,
    );

    bus.emit(
      EphemeralChatEvent.presence(
        userId: remote,
        status: UserPresenceStatus.dnd,
        voiceChannelId: _channel.value,
        expiresAtMs: now + 90,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(service.peers[remote]?.status, UserPresenceStatus.dnd);
    expect(service.peers[remote]?.voiceChannelId, _channel.value);

    bus.emit(
      EphemeralChatEvent.typing(
        userId: remote,
        channelId: _channel,
        expiresAtMs: now + 6,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(service.typingIn(_channel), contains(remote));

    now += 10;
    expect(service.typingIn(_channel), isEmpty);
    expect(service.peers[remote], isNotNull);
    now += 100;
    expect(service.peers[remote], isNull);

    await service.setStatus(UserPresenceStatus.idle);
    await Future<void>.delayed(Duration.zero);
    expect(bus.published.last.status, UserPresenceStatus.idle);
    await service.close();
    await bus.close();
  });

  test(
    '4. 50 MiB file: 16 KiB chunks, two sources, corruption and resume',
    () async {
      const size = 50 * 1024 * 1024;
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i++) {
        bytes[i] = (i * 31 + 7) & 0xff;
      }

      final a = FileTransferServiceImpl(store: MemoryBlobStore());
      final b = FileTransferServiceImpl(store: MemoryBlobStore());
      final c = FileTransferServiceImpl(store: MemoryBlobStore());
      final manifest = (await a.prepare(
        bytes,
        fileName: 'large.bin',
        mimeType: 'application/octet-stream',
      )).unwrap();
      expect(manifest.chunkSize, FileLimits.chunkSize);
      expect(manifest.chunkCount, 3200);

      (await a.seed(manifest, bytes)).unwrap();
      (await c.seed(manifest, bytes)).unwrap();

      final smallBytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024, (i) => (i * 13) & 0xff),
      );
      final parallelA = FileTransferServiceImpl(store: MemoryBlobStore());
      final parallelC = FileTransferServiceImpl(store: MemoryBlobStore());
      final parallelD = FileTransferServiceImpl(store: MemoryBlobStore());
      final smallManifest = (await parallelA.prepare(smallBytes)).unwrap();
      (await parallelA.seed(smallManifest, smallBytes)).unwrap();
      (await parallelC.seed(smallManifest, smallBytes)).unwrap();
      final parallelAStats = _StoreSource('a', parallelA.store);
      final parallelCStats = _StoreSource('c', parallelC.store);
      final parallel = (await parallelD.download(smallManifest, [
        parallelAStats,
        parallelCStats,
      ], window: 16)).unwrap();
      expect(parallel.completed, isTrue);
      expect(parallel.chunksBySource.keys, containsAll(['a', 'c']));
      expect(parallelAStats.maxInFlight, lessThanOrEqualTo(16));
      expect(parallelCStats.maxInFlight, lessThanOrEqualTo(16));

      final sourceA = _StoreSource('a', a.store, failAfter: 100);
      final sourceC = _StoreSource('c', c.store);
      final first = await b.download(manifest, [sourceA], window: 16);
      expect(first.unwrap().completed, isFalse);
      expect(first.unwrap().received, greaterThan(0));

      final downloaded = <String>{};
      final resumed = await b.download(manifest, [sourceC], window: 16);
      expect(resumed.unwrap().completed, isTrue);
      expect(resumed.unwrap().missing, isEmpty);
      downloaded.addAll(sourceC.requested.map((index) => '$index'));
      expect(downloaded.length, lessThan(manifest.chunkCount));
      expect(
        sourceA.requested.length + sourceC.requested.length,
        greaterThanOrEqualTo(manifest.chunkCount),
      );

      final restored = (await b.readAll(manifest)).unwrap();
      expect(restored.length, size);
      expect(restored, orderedEquals(bytes));

      final corrupt = _StoreSource('corrupt', c.store, corruptIndex: 10);
      final d = FileTransferServiceImpl(store: MemoryBlobStore());
      final corruptResult = await d.download(manifest, [corrupt], window: 8);
      expect(corruptResult.unwrap().completed, isFalse);
      expect(corruptResult.unwrap().missing, contains(10));

      final healed = await d.download(manifest, [sourceC], window: 8);
      expect(healed.unwrap().completed, isTrue);
      expect((await d.readAll(manifest)).unwrap(), orderedEquals(bytes));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('5. limits, quota and rate limit are enforced', () async {
    var now = 1000;
    final a = await _replica(0, () => now++);
    await a.engine.createGroup(_group);

    final oversized = 'x' * (ChatLimits.maxTextBytes + 1);
    final tooLarge = await a.chat.send(_group, _channel, oversized);
    expect(tooLarge.unwrapErr(), isA<MessageTooLarge>());

    final limited = ChatServiceImpl(
      engine: a.engine,
      localUser: a.identity.author,
      nowMs: () => now,
      maxMessagesPerWindow: 2,
      rateWindow: const Duration(seconds: 10),
    );
    expect((await limited.send(_group, _channel, 'one')).isOk, isTrue);
    expect((await limited.send(_group, _channel, 'two')).isOk, isTrue);
    final third = await limited.send(_group, _channel, 'three');
    expect(third.unwrapErr(), isA<RateLimited>());

    final file = FileTransferServiceImpl(
      store: MemoryBlobStore(),
      maxStoreBytes: 1024,
    );
    final manifest = (await file.prepare(
      Uint8List.fromList(List<int>.generate(2048, (i) => i & 0xff)),
      fileName: 'over.bin',
    )).unwrap();
    final quota = await file.seed(
      manifest,
      Uint8List.fromList(List<int>.generate(2048, (i) => i & 0xff)),
    );
    expect(quota.unwrapErr(), isA<QuotaExceeded>());

    await limited.close();
    await a.chat.close();
  });

  test('6. notifications: mention/reply, DND and read cancellation', () async {
    final user = (await Ed25519Identity.create(0)).author;
    final other = (await Ed25519Identity.create(1)).author;
    final notifications = FakeNotificationService();
    final router = ChatNotificationRouter(notifications: notifications);

    final message = ChatMessage(
      id: 'm1',
      channelId: 'general',
      authorId: 'author',
      content: 'hello',
      timestamp: 1,
      mentions: [user],
    );
    final view = ChatView(
      channelId: _channel,
      messages: [message],
      readMarkers: const {},
    );

    await router.handle(view, currentUser: user, groupId: _group);
    expect(notifications.shown, hasLength(1));
    expect(notifications.shown.single.kind, ChatNotificationKind.mention);
    expect(notifications.shown.single.groupId, _group);

    await router.handle(view, currentUser: user, groupId: _group, dnd: true);
    expect(notifications.shown, hasLength(1));

    await router.handleRead(view, currentUser: user);
    expect(notifications.cancelled, contains('m1'));

    final reply = ChatMessage(
      id: 'm2',
      channelId: 'general',
      authorId: 'author',
      content: 'reply',
      timestamp: 2,
      replyTo: 'mine',
      replyToAuthorId: other.value,
    );
    final replyNotifications = FakeNotificationService();
    final router2 = ChatNotificationRouter(notifications: replyNotifications);
    await router2.handle(
      ChatView(channelId: _channel, messages: [reply], readMarkers: const {}),
      currentUser: other,
      groupId: _group,
    );
    expect(replyNotifications.shown.single.kind, ChatNotificationKind.reply);
  });
}

class _StoreSource implements BlobSource {
  _StoreSource(this.peerId, this.store, {this.failAfter, this.corruptIndex});

  @override
  final String peerId;
  final BlobStore store;
  final int? failAfter;
  final int? corruptIndex;
  final Set<int> requested = <int>{};
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<List<int>?> fetchChunk(String fileId, int index) async {
    requested.add(index);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    await Future<void>.delayed(Duration.zero);
    inFlight--;
    if (failAfter != null && requested.length > failAfter!) return null;
    final data = await store.readChunk(fileId, index);
    if (data == null) return null;
    if (index == corruptIndex) {
      final copy = List<int>.from(data);
      copy[0] ^= 0xff;
      return copy;
    }
    return data;
  }
}
