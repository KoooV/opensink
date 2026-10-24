import 'dart:async';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/memory_store.dart';
import 'support/test_signer.dart';

class RecordingLink implements SyncLink {
  RecordingLink(this.peerId);

  @override
  final String peerId;

  final List<Uint8List> sent = [];
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) async => sent.add(bytes);

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

void main() {
  group('priority loading', () {
    test('channel window returns the latest N messages', () async {
      final author = testAuthor(0);
      final store = MemorySyncEventStore();
      final engine = SyncEngineImpl(
        store: store,
        signer: TestSigner(author.value),
        localAuthor: author,
      );
      const group = GroupId('g');
      const channel = ChannelId('c');
      await engine.createGroup(group);
      await engine.createChannel(group, channel, name: 'general');
      for (var i = 0; i < 10; i++) {
        await engine.postMessage(group, channel, 'm$i');
      }

      final window = await engine.channelWindow(group, channel, limit: 3);
      expect(window, hasLength(3));
      expect(
        window.map((event) => String.fromCharCodes(event.payload)).toList(),
        <String>['m7', 'm8', 'm9'],
      );
      await engine.close();
    });

    test('window request is sent before summary when a link appears', () async {
      final author = testAuthor(0);
      final store = MemorySyncEventStore();
      final engine = SyncEngineImpl(
        store: store,
        signer: TestSigner(author.value),
        localAuthor: author,
      );
      const group = GroupId('g');
      const channel = ChannelId('c');
      await engine.createGroup(group);
      await engine.createChannel(group, channel, name: 'general');
      await engine.postMessage(group, channel, 'hello');

      final link = RecordingLink('peer');
      await engine.attach(link);
      await engine.drain();

      const codec = SyncFrameCodec();
      final frames = link.sent
          .map((bytes) => codec.decode(bytes).unwrap())
          .toList();
      expect(frames.first, isA<WindowRequestFrame>());
      expect(frames.whereType<SummaryFrame>(), isNotEmpty);
      final window = frames.whereType<WindowRequestFrame>().first;
      expect(window.groupId, group);
      expect(window.channelId, channel);
      await engine.close();
    });
  });
}
