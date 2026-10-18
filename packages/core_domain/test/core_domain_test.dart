import 'package:test/test.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_domain/src/interfaces/fakes.dart';

void main() {
  group('Group.apply — чистая функция от событий', () {
    test('создание группы инициализирует состояние', () {
      final owner = UserId('user-1');
      final alice = UserId('user-2');
      final event = GroupCreated(
        id: EventId('evt-1'),
        groupId: GroupId('group-1'),
        authorId: owner,
        timestamp: 1000,
        signature: 'sig',
        name: 'My Group',
        ownerId: owner,
        initialMembers: {owner, alice},
      );

      final group = Group(
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
      final owner = UserId('user-1');
      final group = Group(
        id: GroupId('group-1'),
        name: 'Old',
        ownerId: owner,
        memberIds: {owner},
        channelIds: {},
        eventIds: {},
        createdAt: 100,
        updatedAt: 100,
      );

      final event = GroupRenamed(
        id: EventId('evt-2'),
        groupId: GroupId('group-1'),
        authorId: owner,
        timestamp: 200,
        signature: 'sig',
        name: 'New',
      );

      final next = group.apply(event);

      expect(group.name, 'Old');
      expect(group.updatedAt, 100);
      expect(next.name, 'New');
      expect(next.updatedAt, 200);
    });

    test('добавление и удаление участника', () {
      final owner = UserId('user-1');
      final bob = UserId('user-3');
      final group = Group(
        id: GroupId('group-1'),
        name: 'G',
        ownerId: owner,
        memberIds: {owner},
        channelIds: {},
        eventIds: {},
        createdAt: 100,
        updatedAt: 100,
      );

      final added = group.apply(MemberAdded(
        id: EventId('evt-a'),
        groupId: GroupId('group-1'),
        authorId: owner,
        timestamp: 101,
        signature: 'sig',
        userId: bob,
      ));

      expect(added.memberIds, {owner, bob});

      final removed = added.apply(MemberRemoved(
        id: EventId('evt-r'),
        groupId: GroupId('group-1'),
        authorId: owner,
        timestamp: 102,
        signature: 'sig',
        userId: bob,
      ));

      expect(removed.memberIds, {owner});
    });

    test('создание канала отражается в состоянии группы', () {
      final owner = UserId('user-1');
      final group = Group(
        id: GroupId('group-1'),
        name: 'G',
        ownerId: owner,
        memberIds: {owner},
        channelIds: {},
        eventIds: {},
        createdAt: 100,
        updatedAt: 100,
      );

      final channelId = ChannelId('channel-1');
      final next = group.apply(ChannelCreated(
        id: EventId('evt-c'),
        groupId: GroupId('group-1'),
        authorId: owner,
        timestamp: 103,
        signature: 'sig',
        channelId: channelId,
        name: 'general',
        type: 'text',
      ));

      expect(next.channelIds, {channelId});
    });
  });

  group('GroupEvent.validateInvariants', () {
    test('GroupCreated с пустым именем — ошибка', () {
      final event = GroupCreated(
        id: EventId('evt-1'),
        groupId: GroupId('g'),
        authorId: UserId('u'),
        timestamp: 1000,
        signature: 'sig',
        name: '',
        ownerId: UserId('u'),
        initialMembers: {UserId('u')},
      );

      final result = event.validateInvariants();
      expect(result.isErr, isTrue);
      result.when(
        ok: (_) => fail('ожидалась ошибка'),
        err: (e) => expect(e, isA<GroupEventError.EmptyName>()),
      );
    });

    test('GroupCreated без初始ных участников — ошибка', () {
      final event = GroupCreated(
        id: EventId('evt-1'),
        groupId: GroupId('g'),
        authorId: UserId('u'),
        timestamp: 1000,
        signature: 'sig',
        name: 'G',
        ownerId: UserId('u'),
        initialMembers: {},
      );

      final result = event.validateInvariants();
      expect(result.isErr, isTrue);
      result.when(
        ok: (_) => fail('ожидалась ошибка'),
        err: (e) => expect(e, isA<GroupEventError.NoInitialMembers>()),
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

    test('when диспатчит по варианту', () {
      const result = Ok<int, String>(7);
      final value = result.when(
        ok: (v) => v * 2,
        err: (e) => -1,
      );
      expect(value, 14);
    });
  });

  group('Fake transports', () {
    test('FakeSignalingChannel доставляет сообщение в incoming', () async {
      final channel = FakeSignalingChannel();
      final received = <SignalingMessage>[];
      final sub = channel.incoming.listen((m) => received.add(m));

      await channel.send(PeerId('peer-1'), const SignalingMessage(type: 'offer', payload: {}, timestamp: 1));
      channel.emit(const SignalingMessage(type: 'answer', payload: {}, timestamp: 2));

      await Future.delayed(Duration.zero);
      expect(received.length, 1);
      expect(received.first.type, 'answer');
      expect(channel.sent.length, 1);
      expect(channel.sent.first.type, 'offer');

      await sub.cancel();
      await channel.close();
    });

    test('FakePeerLink отправляет и эмулирует входящие данные', () async {
      final link = FakePeerLink(PeerId('peer-1'));
      final received = <List<int>>[];
      link.incoming.listen((data) => received.add(data));

      await link.sendData([1, 2, 3]);
      link.emitData([4, 5, 6]);

      await Future.delayed(Duration.zero);
      expect(link.sent, [[1, 2, 3]]);
      expect(received, [[4, 5, 6]]);
      expect(link.state.first, ConnectionState.connected);

      await link.close();
    });

    test('FakeSecureKeyStore хранит и загружает идентичность', () async {
      final store = FakeSecureKeyStore();
      final userId = UserId('user-1');
      expect(await store.hasIdentity(userId), isFalse);

      await store.storeIdentity(
        userId,
        const IdentityBundle(
          userId: UserId('user-1'),
          publicKey: 'abc',
          encryptedPrivateKey: [1, 2, 3],
          createdAt: 1000,
        ),
      );

      expect(await store.hasIdentity(userId), isTrue);
      final loaded = await store.loadIdentity(userId);
      expect(loaded?.publicKey, 'abc');

      await store.deleteIdentity(userId);
      expect(await store.hasIdentity(userId), isFalse);
    });
  });
}
