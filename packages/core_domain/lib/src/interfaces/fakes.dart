import 'dart:async';

/// In-memory fake реализации всех интерфейсов core_domain для тестов.
library core_domain.fakes;

import '../models/entity_id.dart';
import '../models/group.dart';
import '../models/message.dart';
import '../events/group_event.dart';
import '../result.dart';
import 'signaling_channel.dart';
import 'peer_link.dart';
import 'transport.dart';
import 'relay.dart';
import 'media_topology.dart';
import 'event_store.dart';
import 'secure_key_store.dart';
import 'screen_capture_source.dart';

class FakeSignalingChannel implements SignalingChannel {
  final _controller = StreamController<SignalingMessage>.broadcast();
  final _sent = <SignalingMessage>[];

  @override
  Stream<SignalingMessage> get incoming => _controller.stream;

  List<SignalingMessage> get sent => List.unmodifiable(_sent);

  @override
  Future<void> send(PeerId to, SignalingMessage message) async {
    _sent.add(message);
  }

  @override
  Future<void> close() async => await _controller.close();

  void emit(SignalingMessage message) => _controller.add(message);
}

class FakePeerLink implements PeerLink {
  final _dataController = StreamController<List<int>>.broadcast();
  final _stateController = StreamController<ConnectionState>.broadcast();
  final _sent = <List<int>>[];

  @override
  final PeerId remotePeerId;

  FakePeerLink(this.remotePeerId) {
    _stateController.add(ConnectionState.connected);
  }

  @override
  Stream<List<int>> get incomingData => _dataController.stream;

  @override
  Stream<ConnectionState> get state => _stateController.stream;

  List<List<int>> get sent => List.unmodifiable(_sent);

  @override
  Future<void> sendData(List<int> data) async => _sent.add(data);

  @override
  Future<void> setRemoteDescription(String sdp, String type) async {}

  @override
  Future<String> createOffer() async => 'fake-offer';

  @override
  Future<String> createAnswer() async => 'fake-answer';

  @override
  Future<void> addIceCandidate(String candidate, String sdpMid, int sdpMLineIndex) async {}

  @override
  Future<void> close() async {
    await _dataController.close();
    await _stateController.close();
  }

  void emitData(List<int> data) => _dataController.add(data);
  void emitState(ConnectionState state) => _stateController.add(state);
}

class FakeTransport implements Transport {
  final _incoming = StreamController<TransportMessage>.broadcast();
  final _sent = <TransportMessage>[];

  @override
  Stream<TransportMessage> get incoming => _incoming.stream;

  @override
  Set<PeerId> get knownPeers => {};

  @override
  Future<void> send(PeerId to, List<int> data) async {
    _sent.add(TransportMessage(from: to, payload: data, timestamp: DateTime.now().millisecondsSinceEpoch));
  }

  @override
  Future<void> close() async => await _incoming.close();

  List<TransportMessage> get sent => List.unmodifiable(_sent);

  void emit(TransportMessage message) => _incoming.add(message);
}

class FakeRelay implements Relay {
  final _incoming = StreamController<RelayMessage>.broadcast();

  @override
  Stream<RelayMessage> get incoming => _incoming.stream;

  @override
  Future<void> relayToGroup(GroupId groupId, List<int> payload) async {}

  @override
  Future<void> close() async => await _incoming.close();

  void emit(RelayMessage message) => _incoming.add(message);
}

class FakeMediaTopology implements MediaTopology {
  final _events = StreamController<MediaEvent>.broadcast();

  @override
  Stream<MediaEvent> get events => _events.stream;

  @override
  Future<void> join(ChannelId channelId) async {}

  @override
  Future<void> leave() async {}

  @override
  Future<void> addTrack(String trackId, MediaTrackKind kind) async {}

  @override
  Future<void> removeTrack(String trackId) async {}

  @override
  Future<void> close() async => await _events.close();

  void emit(MediaEvent event) => _events.add(event);
}

class FakeEventStore implements EventStore {
  final _records = <EventRecord>[];
  final _controller = StreamController<EventRecord>.broadcast();

  @override
  Future<void> write(EventRecord record) async {
    _records.add(record);
    _controller.add(record);
  }

  @override
  Stream<EventRecord> watchFrom(String cursor) => _controller.stream;

  @override
  Stream<EventRecord> watchGroup(GroupId groupId) =>
      _controller.stream.where((r) => r.groupId == groupId);

  @override
  Future<void> close() async => await _controller.close();

  List<EventRecord> get records => List.unmodifiable(_records);
}

class FakeSecureKeyStore implements SecureKeyStore {
  final _store = <UserId, IdentityBundle>{};

  @override
  Future<void> storeIdentity(UserId userId, IdentityBundle bundle) async =>
      _store[userId] = bundle;

  @override
  Future<IdentityBundle?> loadIdentity(UserId userId) async => _store[userId];

  @override
  Future<void> deleteIdentity(UserId userId) async => _store.remove(userId);

  @override
  Future<bool> hasIdentity(UserId userId) async => _store.containsKey(userId);
}

class FakeScreenCaptureSource implements ScreenCaptureSource {
  final _frames = StreamController<List<int>>.broadcast();
  var _isCapturing = false;

  @override
  Stream<List<int>> get frames => _frames.stream;

  @override
  Stream<List<int>>? get audioFrames => null;

  @override
  bool get isCapturing => _isCapturing;

  @override
  Future<void> start() async => _isCapturing = true;

  @override
  Future<void> stop() async => _isCapturing = false;

  void emitFrame(List<int> frame) => _frames.add(frame);
}
