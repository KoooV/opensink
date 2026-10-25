import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:core_domain/core_domain.dart';

void main() {
  group('Group.apply — чистая функция от событий', () {
    test('создание группы инициализирует состояние', () {
      const owner = UserId('user-1');
      const alice = UserId('user-2');
      final event = GroupCreated(
        id: const EventId('evt-1'),
        groupId: const GroupId('group-1'),
        authorId: owner,
        timestamp: 1000,
        name: 'My Group',
        ownerId: owner,
        initialMembers: {owner, alice},
      );

      final group = const Group(
        id: GroupId('group-1'),
        name: '',
        ownerId: owner,
        memberIds: {},
        channelIds: {},
        eventIds: {},
        createdAt: 0,
        updatedAt: 0,
      ).apply(event);

      expect(group.name, 'My Group');
      expect(group.ownerId, owner);
      expect(group.memberIds, {owner, alice});
      expect(group.createdAt, 1000);
    });

    test('применение не мутирует исходное состояние', () {
      const owner = UserId('user-1');
      final group = Group(
        id: const GroupId('group-1'),
        name: 'Old',
        ownerId: owner,
        memberIds: {owner},
        channelIds: {},
        eventIds: {},
        createdAt: 100,
        updatedAt: 100,
      );

      const event = GroupRenamed(
        id: EventId('evt-2'),
        groupId: GroupId('group-1'),
        authorId: owner,
        timestamp: 200,
        name: 'New',
      );

      final next = group.apply(event);

      expect(group.name, 'Old');
      expect(group.updatedAt, 100);
      expect(next.name, 'New');
      expect(next.updatedAt, 200);
    });
  });

  group('GroupEvent.validateInvariants', () {
    test('GroupCreated с пустым именем — ошибка', () {
      final event = GroupCreated(
        id: const EventId('evt-1'),
        groupId: const GroupId('g'),
        authorId: const UserId('u'),
        timestamp: 1000,
        name: '',
        ownerId: const UserId('u'),
        initialMembers: {const UserId('u')},
      );

      final result = event.validateInvariants();
      expect(result.isErr, isTrue);
      result.when(
        ok: (_) => fail('ожидалась ошибка'),
        err: (e) => expect(e, isA<EmptyName>()),
      );
    });

    test('GroupCreated без начальных участников — ошибка', () {
      const event = GroupCreated(
        id: EventId('evt-1'),
        groupId: GroupId('g'),
        authorId: UserId('u'),
        timestamp: 1000,
        name: 'G',
        ownerId: UserId('u'),
        initialMembers: {},
      );

      final result = event.validateInvariants();
      expect(result.isErr, isTrue);
      result.when(
        ok: (_) => fail('ожидалась ошибка'),
        err: (e) => expect(e, isA<NoInitialMembers>()),
      );
    });
  });

  group('Result', () {
    test('Ok.unwrap возвращает значение', () {
      const result = Ok<int, String>(42);
      expect(result.unwrap(), 42);
      expect(result.isOk, isTrue);
      expect(result.isErr, isFalse);
    });

    test('Err.unwrapErr возвращает ошибку', () {
      const result = Err<int, String>('boom');
      expect(result.unwrapErr(), 'boom');
      expect(result.isErr, isTrue);
    });
  });

  group('PeerId', () {
    test('равенство по байтам открытого ключа', () {
      final a = PeerId(Uint8List.fromList([1, 2, 3]));
      final b = PeerId(Uint8List.fromList([1, 2, 3]));
      final c = PeerId(Uint8List.fromList([1, 2, 4]));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a != c, isTrue);
    });
  });

  group('FakeSignalingChannel', () {
    test('join/publish/incoming доставляют сообщение по теме', () async {
      final channel = FakeSignalingChannel();
      await channel.join('topic-1');
      final received = <SignalingMessage>[];
      final sub = channel.incoming.listen(received.add);

      await channel.publish('topic-1', [1, 2, 3]);
      channel.emit(SignalingMessage(
        topic: 'topic-1',
        bytes: [4, 5, 6],
        from: PeerId(Uint8List.fromList([9])),
        timestamp: 2,
      ));

      await Future.delayed(Duration.zero);
      expect(received.length, 1);
      expect(received.first.bytes, [4, 5, 6]);
      expect(channel.sent.length, 1);
      expect(channel.joined, {'topic-1'});

      await sub.cancel();
      await channel.close();
    });
  });

  group('FakePeerLink', () {
    test('send/incoming/state/stats/close', () async {
      final link = FakePeerLink(PeerId(Uint8List.fromList([7])));
      final received = <Incoming>[];
      link.incoming.listen(received.add);

      await link.send('chat', [1, 2, 3]);
      link.emitIncoming(const Incoming(
        channel: 'chat',
        bytes: [4, 5, 6],
        timestamp: 1,
      ));

      await Future.delayed(Duration.zero);
      expect(link.sent.length, 1);
      expect(link.sent.first.channel, 'chat');
      expect(received.map((i) => i.bytes).toList(), [[4, 5, 6]]);
      expect(link.state, PeerLinkState.connected);
      expect(link.stats.rtt.inMilliseconds, 10);

      link.emitState(PeerLinkState.closed);
      expect(link.state, PeerLinkState.closed);

      await link.close();
    });
  });

  group('FakeTransport', () {
    test('connect/events/send/close', () async {
      final transport = FakeTransport();
      final events = <PeerLinkEvent>[];
      transport.events.listen(events.add);

      final link = await transport.connect(PeerId(Uint8List.fromList([8])));
      await transport.send(PeerId(Uint8List.fromList([8])), [9, 9]);

      await Future.delayed(Duration.zero);
      expect(events.length, 1);
      expect(events.first.type, 'connected');
      expect(link.remotePeerId, PeerId(Uint8List.fromList([8])));

      await transport.close();
    });
  });

  group('FakeRelay', () {
    test('routes/forward/capacity', () async {
      final relay = FakeRelay();
      relay.routeTo(PeerId(Uint8List.fromList([5])));
      expect(relay.routes(PeerId(Uint8List.fromList([5]))), isTrue);
      expect(relay.routes(PeerId(Uint8List.fromList([6]))), isFalse);

      await relay.forward(RelayFrame(
        src: PeerId(Uint8List.fromList([7])),
        dst: PeerId(Uint8List.fromList([5])),
        payload: [1, 2, 3],
      ));

      expect(relay.forwarded.length, 1);
      expect(relay.capacity, 1000);
      await relay.close();
    });
  });

  group('FakeMediaTopology', () {
    test('plan возвращает mesh с участниками', () {
      final topology = FakeMediaTopology();
      final plan = topology.plan(
        {PeerId(Uint8List.fromList([1])), PeerId(Uint8List.fromList([2]))},
        {},
      );
      expect(plan.type, TopologyType.mesh);
      expect(plan.participants.length, 2);
      expect(topology.plans.length, 1);
    });
  });

  group('FakeEventStore', () {
    test('write/watchGroup', () async {
      final store = FakeEventStore();
      final record = EventRecord(
        id: 'evt-1',
        groupId: const GroupId('g-1'),
        author: List.filled(32, '01').join(),
        payload: [1, 2],
        timestamp: 1000,
        signature: 'sig',
      );
      final received = <EventRecord>[];
      store.watchGroup(const GroupId('g-1')).listen(received.add);

      await store.write(record);

      await Future.delayed(Duration.zero);
      expect(received.length, 1);
      await store.close();
    });
  });

  group('FakeSyncEngine', () {
    test('sync/changes', () async {
      final engine = FakeSyncEngine();
      final changes = <void>[];
      engine.changes.listen((_) => changes.add(null));

      await engine.sync();
      await Future.delayed(Duration.zero);
      expect(engine.synced, isTrue);
      expect(changes.length, 1);
      await engine.close();
    });
  });

  group('FakeGroupState', () {
    test('state/watch', () async {
      final state = GroupState(
        id: const GroupId('g-1'),
        name: 'G',
        ownerId: const UserId('u-1'),
        memberIds: {const UserId('u-1')},
        channelIds: {},
        createdAt: 100,
        updatedAt: 100,
      );
      final fake = FakeGroupState(state);
      expect(fake.state.name, 'G');

      final watched = <GroupState>[];
      fake.watch().listen(watched.add);

      final next = GroupState(
        id: state.id,
        name: 'New',
        ownerId: state.ownerId,
        memberIds: state.memberIds,
        channelIds: state.channelIds,
        createdAt: state.createdAt,
        updatedAt: state.updatedAt + 1,
      );
      fake.setState(next);
      await Future.delayed(Duration.zero);

      expect(fake.state.name, 'New');
      expect(watched.length, 1);
      expect(watched.first.name, 'New');
    });
  });

  group('FakeSecureKeyStore', () {
    test('хранит и загружает идентичность', () async {
      final store = FakeSecureKeyStore();
      const userId = UserId('user-1');
      final has = await store.hasIdentity(userId);
      expect(has.isOk, isTrue);
      expect((has as Ok<bool, KeyStoreError>).value, isFalse);

      await store.storeIdentity(
        userId,
        const IdentityBundle(
          userId: UserId('user-1'),
          publicKey: 'abc',
          privateSeed: [1, 2, 3],
          createdAt: 1000,
        ),
      );
      final stored = await store.storeIdentity(
        userId,
        const IdentityBundle(
          userId: UserId('user-1'),
          publicKey: 'abc',
          privateSeed: [1, 2, 3],
          createdAt: 1000,
        ),
      );
      expect(stored.isOk, isTrue);

      final hasAfter = await store.hasIdentity(userId);
      expect(hasAfter.isOk, isTrue);
      expect((hasAfter as Ok<bool, KeyStoreError>).value, isTrue);
      final loaded = await store.loadIdentity(userId);
      expect(loaded.isOk, isTrue);
      expect((loaded as Ok<IdentityBundle, KeyStoreError>).value.publicKey, 'abc');

      final deleted = await store.deleteIdentity(userId);
      expect(deleted.isOk, isTrue);
      final hasDeleted = await store.hasIdentity(userId);
      expect(hasDeleted.isOk, isTrue);
      expect((hasDeleted as Ok<bool, KeyStoreError>).value, isFalse);
    });
  });

  group('FakeScreenCaptureSource', () {
    test('start/stop/isCapturing/frames', () async {
      final source = FakeScreenCaptureSource();
      expect(source.isCapturing, isFalse);

      final frames = <List<int>>[];
      source.frames.listen(frames.add);

      await source.start();
      expect(source.isCapturing, isTrue);

      source.emitFrame([1, 2, 3]);
      await Future.delayed(Duration.zero);
      expect(frames, [[1, 2, 3]]);

      await source.stop();
      expect(source.isCapturing, isFalse);
    });
  });
}
