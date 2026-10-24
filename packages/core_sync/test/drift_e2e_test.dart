import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/drift_backend.dart';
import 'support/ed25519_identity.dart';
import 'support/simulator.dart';

void main() {
  group('SyncEngineImpl over DriftEventStore', () {
    test(
      'two replicas converge and state rehydrates after engine restart',
      () async {
        final aHandle = await openDriftStore('sync-e2e-a');
        final bHandle = await openDriftStore('sync-e2e-b');
        final network = SimulatedNetwork(Random(7));
        final aIdentity = await Ed25519Identity.create(0);
        final bIdentity = await Ed25519Identity.create(1);

        final a = SyncEngineImpl(
          store: aHandle.store,
          signer: aIdentity.signer,
          localAuthor: aIdentity.author,
        );
        final b = SyncEngineImpl(
          store: bHandle.store,
          signer: bIdentity.signer,
          localAuthor: bIdentity.author,
        );
        SyncEngineImpl? restartedA;

        const group = GroupId('drift-group');
        const channel = ChannelId('drift-channel');

        try {
          await a.attach(
            SimulatedLink(
              network: network,
              from: 0,
              to: 1,
              peerId: bIdentity.author.value,
            ),
          );
          await b.attach(
            SimulatedLink(
              network: network,
              from: 1,
              to: 0,
              peerId: aIdentity.author.value,
            ),
          );

          expect((await a.createGroup(group)).isOk, isTrue);
          expect((await a.addMember(group, bIdentity.author)).isOk, isTrue);
          expect(
            (await a.createChannel(group, channel, name: 'general')).isOk,
            isTrue,
          );
          await _pump(network, [a, b]);

          for (var i = 0; i < 3; i++) {
            expect(
              (await a.postMessage(group, channel, 'message-$i')).isOk,
              isTrue,
            );
          }
          await _pump(network, [a, b]);

          final reference = await a.projection(group);
          final referenceIds = (await a.allEvents(group))
              .map((event) => event.id.value)
              .toList();
          expect(reference.messages, hasLength(3));
          expect(await b.projection(group), reference);

          await a.close();
          restartedA = SyncEngineImpl(
            store: aHandle.store,
            signer: aIdentity.signer,
            localAuthor: aIdentity.author,
          );
          await restartedA.registerGroup(group);

          expect(
            (await restartedA.allEvents(group))
                .map((event) => event.id.value)
                .toList(),
            referenceIds,
          );
          expect(await restartedA.projection(group), reference);
        } finally {
          await restartedA?.close();
          await a.close();
          await b.close();
          await aHandle.close();
          await bHandle.close();
        }
      },
    );

    test('channel-scoped requestHistory returns only that channel', () async {
      final aHandle = await openDriftStore('sync-history-a');
      final bHandle = await openDriftStore('sync-history-b');
      final aIdentity = await Ed25519Identity.create(0);
      final bIdentity = await Ed25519Identity.create(1);

      final a = SyncEngineImpl(
        store: aHandle.store,
        signer: aIdentity.signer,
        localAuthor: aIdentity.author,
      );
      final b = SyncEngineImpl(
        store: bHandle.store,
        signer: bIdentity.signer,
        localAuthor: bIdentity.author,
      );

      const group = GroupId('history-group');
      const c1 = ChannelId('history-c1');
      const c2 = ChannelId('history-c2');
      const codec = SyncEventCodec();

      try {
        expect((await a.createGroup(group)).isOk, isTrue);
        expect((await a.addMember(group, bIdentity.author)).isOk, isTrue);
        expect((await a.createChannel(group, c1)).isOk, isTrue);
        expect((await a.createChannel(group, c2)).isOk, isTrue);
        final c1Events = <String>[];
        final c2Events = <String>[];
        for (var i = 0; i < 4; i++) {
          final result = await a.postMessage(group, c1, 'c1-$i');
          expect(result.isOk, isTrue);
          c1Events.add(result.unwrap().id.value);
          final other = await a.postMessage(group, c2, 'c2-$i');
          expect(other.isOk, isTrue);
          c2Events.add(other.unwrap().id.value);
        }

        // B знает membership и каналы, но ещё не получил сообщения.
        for (final record in await aHandle.store.groupEvents(group)) {
          final decoded = codec.fromRecord(record);
          if (decoded.isErr) continue;
          final event = decoded.unwrap();
          const controlKinds = {
            SyncEventKind.groupCreated,
            SyncEventKind.memberAdded,
            SyncEventKind.memberRemoved,
            SyncEventKind.channelCreated,
            SyncEventKind.channelDeleted,
            SyncEventKind.groupRenamed,
            SyncEventKind.ownerTransferred,
          };
          if (!controlKinds.contains(event.kind)) continue;
          final written = await bHandle.store.write(record);
          expect(written.isOk, isTrue);
        }

        await b.registerGroup(group);
        expect(
          (await b.allEvents(group)).map((event) => event.id.value),
          isNot(contains(c1Events.first)),
        );

        final pair = _HistoryOnlyPair(
          clientPeer: aIdentity.author.value,
          serverPeer: bIdentity.author.value,
        );
        await a.attach(pair.server);
        await b.attach(pair.client);
        await _pumpPair(a, b);

        await b.requestHistory(group, channelId: c1);
        await _pumpPair(a, b);

        expect(pair.requests, isNotEmpty);
        expect(pair.requests.first.channelId, c1);

        final bIds = (await b.allEvents(group))
            .map((event) => event.id.value)
            .toSet();
        expect(bIds.containsAll(c1Events), isTrue);
        expect(bIds.intersection(c2Events.toSet()), isEmpty);
      } finally {
        await a.close();
        await b.close();
        await aHandle.close();
        await bHandle.close();
      }
    });

    test(
      'pending event survives engine restart and applies after membership',
      () async {
        final handle = await openDriftStore('sync-pending');
        final aIdentity = await Ed25519Identity.create(0);
        final bIdentity = await Ed25519Identity.create(1);
        const group = GroupId('pending-group');
        const channel = ChannelId('pending-channel');
        final now = DateTime.now().millisecondsSinceEpoch;

        final a = SyncEngineImpl(
          store: handle.store,
          signer: aIdentity.signer,
          localAuthor: aIdentity.author,
        );
        SyncEngineImpl? restartedA;

        try {
          expect((await a.createGroup(group)).isOk, isTrue);
          expect((await a.createChannel(group, channel)).isOk, isTrue);

          final memberEvent = await _signedEvent(
            identity: aIdentity,
            groupId: group,
            kind: SyncEventKind.memberAdded,
            targetId: bIdentity.author.value,
            hlc: Hlc(now + 1000, 0),
          );
          final messageEvent = await _signedEvent(
            identity: bIdentity,
            groupId: group,
            channelId: channel,
            kind: SyncEventKind.messageCreated,
            payload: Uint8List.fromList(utf8.encode('early')),
            hlc: Hlc(now + 2000, 0),
          );

          final pending = await a.ingest(messageEvent);
          expect(pending.isOk, isTrue);
          expect(pending.unwrap().outcome, IngestOutcome.pending);
          expect(await handle.store.pendingEvents(group), hasLength(1));
          expect((await a.projection(group)).messages, isEmpty);

          await a.close();
          restartedA = SyncEngineImpl(
            store: handle.store,
            signer: aIdentity.signer,
            localAuthor: aIdentity.author,
          );
          await restartedA.registerGroup(group);

          expect(await handle.store.pendingEvents(group), hasLength(1));
          expect((await restartedA.projection(group)).messages, isEmpty);

          final applied = await restartedA.ingest(memberEvent);
          expect(applied.isOk, isTrue);
          expect(applied.unwrap().outcome, IngestOutcome.inserted);

          final projection = await restartedA.projection(group);
          expect(projection.messages, hasLength(1));
          expect(projection.messages.values.single.content, 'early');
          expect(await handle.store.pendingEvents(group), isEmpty);
        } finally {
          await restartedA?.close();
          await a.close();
          await handle.close();
        }
      },
    );
  });
}

Future<SyncEvent> _signedEvent({
  required Ed25519Identity identity,
  required GroupId groupId,
  required SyncEventKind kind,
  required Hlc hlc,
  ChannelId? channelId,
  String? targetId,
  Uint8List? payload,
}) async {
  final draft = SyncEvent(
    id: const EventId(''),
    groupId: groupId,
    channelId: channelId,
    authorId: identity.author,
    hlc: hlc,
    kind: kind,
    targetId: targetId,
    payload: payload,
  );
  final id = draft.computeId();
  final unsigned = draft.copyWith(id: EventId(id));
  final signature = await identity.signer.sign(unsigned.signedBytes());
  return unsigned.copyWith(signature: signature);
}

Future<void> _pump(
  SimulatedNetwork network,
  List<SyncEngineImpl> engines, {
  int maxIterations = 300,
}) async {
  for (var i = 0; i < maxIterations; i++) {
    final hadPackets = network.queueLength;
    await network.flush();
    await Future.wait(engines.map((engine) => engine.drain()));
    await Future<void>.delayed(Duration.zero);
    if (network.queueLength == 0 && hadPackets == 0) return;
  }
  throw StateError('drift e2e network did not settle');
}

Future<void> _pumpPair(
  SyncEngineImpl a,
  SyncEngineImpl b, {
  int rounds = 40,
}) async {
  for (var i = 0; i < rounds; i++) {
    await a.drain();
    await b.drain();
    await Future<void>.delayed(Duration.zero);
  }
}

class _FilteredLink implements SyncLink {
  _FilteredLink(this.peerId, this._onSend);

  @override
  final String peerId;

  final void Function(Uint8List bytes) _onSend;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) async {
    if (!_closed) _onSend(bytes);
  }

  void deliver(Uint8List bytes) {
    if (!_closed && !_incoming.isClosed) _incoming.add(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}

/// Передаёт только явные RangeRequest/EventsFrame, отбрасывая summary,
/// оконные запросы и gossip, чтобы тест проверял именно requestHistory.
class _HistoryOnlyPair {
  _HistoryOnlyPair({required String clientPeer, required String serverPeer}) {
    const codec = SyncFrameCodec();
    client = _FilteredLink(serverPeer, (bytes) {
      final decoded = codec.decode(bytes);
      if (decoded.isErr) return;
      final frame = decoded.unwrap();
      if (frame is! RangeRequestFrame) return;
      requests.add(frame);
      server.deliver(bytes);
    });
    server = _FilteredLink(clientPeer, (bytes) {
      final decoded = codec.decode(bytes);
      if (decoded.isErr) return;
      if (decoded.unwrap() is EventsFrame) client.deliver(bytes);
    });
  }

  late final _FilteredLink client;
  late final _FilteredLink server;
  final List<RangeRequestFrame> requests = [];
}
