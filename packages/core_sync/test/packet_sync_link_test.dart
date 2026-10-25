import 'dart:async';
import 'dart:typed_data';

import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

class _FakePacketTransport implements SyncPacketTransport {
  final StreamController<SyncPacket> _incoming =
      StreamController<SyncPacket>.broadcast();
  final List<(String, Uint8List)> sent = <(String, Uint8List)>[];
  bool closed = false;

  @override
  Stream<SyncPacket> get incoming => _incoming.stream;

  @override
  Future<void> send(String dst, Uint8List bytes) async {
    sent.add((dst, Uint8List.fromList(bytes)));
  }

  void emit(String src, List<int> payload) {
    _incoming.add(
      SyncPacket(src: src, payload: Uint8List.fromList(payload)),
    );
  }

  Future<void> dispose() async {
    closed = true;
    await _incoming.close();
  }
}

void main() {
  group('PacketSyncLink', () {
    test('отправляет байты на peerId транспорта', () async {
      final transport = _FakePacketTransport();
      addTearDown(transport.dispose);
      final link = PacketSyncLink(transport: transport, peerId: 'peer-a');

      await link.send(Uint8List.fromList(<int>[1, 2, 3]));

      expect(transport.sent, hasLength(1));
      expect(transport.sent.single.$1, 'peer-a');
      expect(transport.sent.single.$2, <int>[1, 2, 3]);
    });

    test('incoming содержит только пакеты своего peer', () async {
      final transport = _FakePacketTransport();
      addTearDown(transport.dispose);
      final link = PacketSyncLink(transport: transport, peerId: 'peer-a');
      addTearDown(link.close);

      final received = <List<int>>[];
      final subscription = link.incoming.listen(received.add);
      addTearDown(subscription.cancel);

      transport.emit('peer-b', <int>[7]);
      transport.emit('peer-a', <int>[8, 9]);
      await Future<void>.delayed(Duration.zero);

      expect(received, <List<int>>[
        <int>[8, 9],
      ]);
    });

    test('два линка одного транспорта изолированы по peer', () async {
      final transport = _FakePacketTransport();
      addTearDown(transport.dispose);
      final first = PacketSyncLink(transport: transport, peerId: 'peer-a');
      final second = PacketSyncLink(transport: transport, peerId: 'peer-b');
      addTearDown(first.close);
      addTearDown(second.close);

      final firstReceived = <List<int>>[];
      final secondReceived = <List<int>>[];
      final firstSub = first.incoming.listen(firstReceived.add);
      final secondSub = second.incoming.listen(secondReceived.add);
      addTearDown(firstSub.cancel);
      addTearDown(secondSub.cancel);

      transport.emit('peer-a', <int>[1]);
      transport.emit('peer-b', <int>[2]);
      await Future<void>.delayed(Duration.zero);

      expect(firstReceived, <List<int>>[
        <int>[1],
      ]);
      expect(secondReceived, <List<int>>[
        <int>[2],
      ]);
    });

    test('close не закрывает общий транспорт', () async {
      final transport = _FakePacketTransport();
      addTearDown(transport.dispose);
      final link = PacketSyncLink(transport: transport, peerId: 'peer-a');

      await link.close();

      expect(transport.closed, isFalse);
      await transport.send('peer-b', Uint8List.fromList(<int>[4]));
      expect(transport.sent, hasLength(1));
    });
  });
}
