import 'dart:async';
import 'dart:typed_data';

import '../result.dart';

/// In-memory fake реализации всех интерфейсов core_domain для тестов.

import '../models/identifiers.dart';
import '../interfaces/signaling_channel.dart';
import '../interfaces/signer.dart';
import '../interfaces/peer_link.dart';
import '../interfaces/transport.dart';
import '../interfaces/relay.dart';
import '../interfaces/media_topology.dart';
import '../interfaces/event_store.dart';
import '../interfaces/group_metadata_store.dart';
import '../models/group_metadata.dart';
import '../interfaces/sync_engine.dart';
import '../interfaces/group_state.dart';
import '../interfaces/secure_key_store.dart';
import '../interfaces/screen_capture_source.dart';

// ---------------------------------------------------------------------------
// SignalingChannel
// ---------------------------------------------------------------------------

class FakeSignalingChannel implements SignalingChannel {
  final _controller = StreamController<SignalingMessage>.broadcast();
  final _joined = <String>{};
  final _sent = <SignalingMessage>[];

  @override
  Stream<SignalingMessage> get incoming => _controller.stream;

  List<SignalingMessage> get sent => List.unmodifiable(_sent);
  Set<String> get joined => Set.unmodifiable(_joined);

  @override
  Future<void> join(String topic) async => _joined.add(topic);

  @override
  Future<void> publish(String topic, List<int> bytes) async {
    _sent.add(
      SignalingMessage(
        topic: topic,
        bytes: List<int>.unmodifiable(bytes),
        from: PeerId(Uint8List.fromList([0, 0, 0, 0])),
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<void> close() async => await _controller.close();

  void emit(SignalingMessage message) => _controller.add(message);
}

// ---------------------------------------------------------------------------
// Signer
// ---------------------------------------------------------------------------

class FakeSigner implements Signer {
  final _signatures = <String, String>{}; // data hex -> signature

  @override
  Future<String> sign(Uint8List data) async {
    final hex = data.toList().join(',');
    final sig = 'sig-$hex';
    _signatures[hex] = sig;
    return sig;
  }

  @override
  Future<bool> verify(
    Uint8List data,
    String signatureHex,
    PeerId peerId,
  ) async {
    final hex = data.toList().join(',');
    return _signatures[hex] == signatureHex;
  }
}

// ---------------------------------------------------------------------------
// PeerLink
// ---------------------------------------------------------------------------

class FakePeerLink implements PeerLink {
  final _incomingController = StreamController<Incoming>.broadcast();
  final _stateController = StreamController<PeerLinkState>.broadcast();
  final _sent = <Incoming>[];

  @override
  final PeerId remotePeerId;

  @override
  PeerLinkState get state => _state;

  PeerLinkState _state = PeerLinkState.connected;

  @override
  Stream<PeerLinkState> get stateStream => _stateController.stream;

  @override
  Stream<Incoming> get incoming => _incomingController.stream;

  @override
  PeerLinkStats get stats => const PeerLinkStats(
    rtt: Duration(milliseconds: 10),
    bytesSent: 0,
    bytesReceived: 0,
    loss: 0.0,
  );

  FakePeerLink(this.remotePeerId) {
    _stateController.add(PeerLinkState.connected);
  }

  List<Incoming> get sent => List.unmodifiable(_sent);

  @override
  Future<void> send(String channel, List<int> bytes) async {
    _sent.add(
      Incoming(
        channel: channel,
        bytes: List<int>.unmodifiable(bytes),
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<void> close() async {
    _state = PeerLinkState.closed;
    await _incomingController.close();
    await _stateController.close();
  }

  void emitIncoming(Incoming incoming) => _incomingController.add(incoming);
  void emitState(PeerLinkState state) {
    _state = state;
    _stateController.add(state);
  }
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

class FakeTransport implements Transport {
  final _eventsController = StreamController<PeerLinkEvent>.broadcast();
  final _relayController = StreamController<RelayDatagram>.broadcast();
  final _sent = <PeerLinkEvent>[];
  final _relaySent = <PeerLinkEvent>[];
  final _links = <PeerId, FakePeerLink>{};

  @override
  Stream<PeerLinkEvent> get events => _eventsController.stream;

  @override
  Stream<RelayDatagram> get relayIncoming => _relayController.stream;

  List<PeerLinkEvent> get sent => List.unmodifiable(_sent);

  List<PeerLinkEvent> get relaySent => List.unmodifiable(_relaySent);

  @override
  Future<PeerLink> connect(PeerId peerId) async {
    final link = FakePeerLink(peerId);
    _links[peerId] = link;
    _eventsController.add(PeerLinkEvent('connected', peerId));
    return link;
  }

  @override
  Future<void> send(PeerId dst, List<int> bytes) async {
    _sent.add(PeerLinkEvent('send', dst));
  }

  @override
  Future<void> sendRelay(PeerId dst, List<int> bytes) async {
    _relaySent.add(PeerLinkEvent('sendRelay', dst));
  }

  @override
  Future<void> close() async {
    for (final link in _links.values) {
      await link.close();
    }
    _links.clear();
    await _relayController.close();
    await _eventsController.close();
  }

  void emitEvent(PeerLinkEvent event) => _eventsController.add(event);

  void emitRelay(PeerId from, List<int> bytes) => _relayController.add(
    RelayDatagram(
      from: from,
      bytes: bytes,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

// ---------------------------------------------------------------------------
// Relay
// ---------------------------------------------------------------------------

class FakeRelay implements Relay {
  final _routed = <PeerId>{};
  final _forwarded = <RelayFrame>[];
  final int _capacity = 1000;

  @override
  bool routes(PeerId dst) => _routed.contains(dst);

  @override
  Future<void> forward(RelayFrame frame) async {
    _forwarded.add(frame);
  }

  @override
  int get capacity => _capacity;

  List<RelayFrame> get forwarded => List.unmodifiable(_forwarded);
  Set<PeerId> get routed => Set.unmodifiable(_routed);

  @override
  Future<void> close() async {}

  void routeTo(PeerId peer) => _routed.add(peer);
}

// ---------------------------------------------------------------------------
// MediaTopology
// ---------------------------------------------------------------------------

class FakeMediaTopology implements MediaTopology {
  final _plans = <TopologyPlan>[];

  @override
  TopologyPlan plan(
    Set<PeerId> participants,
    Map<PeerId, PeerCapabilities> capabilities,
  ) {
    final plan = TopologyPlan(
      type: TopologyType.mesh,
      participants: Set.unmodifiable(participants),
    );
    _plans.add(plan);
    return plan;
  }

  List<TopologyPlan> get plans => List.unmodifiable(_plans);

  @override
  Future<void> close() async {}
}

// ---------------------------------------------------------------------------
// EventStore
// ---------------------------------------------------------------------------

class FakeEventStore implements EventStore {
  final _records = <EventRecord>[];
  final _controller = StreamController<EventRecord>.broadcast();

  @override
  Future<Result<InsertOutcome, EventStoreWriteError>> write(
    EventRecord record,
  ) async {
    if (_records.any((existing) => existing.id == record.id)) {
      return const Ok(InsertOutcome(inserted: false, duplicate: true));
    }
    _records.add(record);
    _controller.add(record);
    return const Ok(InsertOutcome(inserted: true, duplicate: false));
  }

  @override
  Stream<EventRecord> watchFrom(String cursor) async* {
    var started = cursor.isEmpty;
    for (final record in _records) {
      if (!started && record.id == cursor) {
        started = true;
      }
      if (started) {
        yield record;
      }
    }
    yield* _controller.stream;
  }

  @override
  Stream<EventRecord> watchGroup(GroupId groupId) async* {
    for (final record in _records) {
      if (record.groupId == groupId) {
        yield record;
      }
    }
    yield* _controller.stream.where((r) => r.groupId == groupId);
  }

  List<EventRecord> get records => List.unmodifiable(_records);

  @override
  Future<void> close() async => await _controller.close();
}

// ---------------------------------------------------------------------------
// GroupMetadataStore
// ---------------------------------------------------------------------------

class MemoryGroupMetadataStore implements GroupMetadataStore {
  final Map<String, GroupMetadata> _groups = {};
  GroupId? _active;

  @override
  Future<Result<GroupMetadata?, GroupMetadataError>> load(
    GroupId groupId,
  ) async {
    return Ok(_groups[groupId.value]);
  }

  @override
  Future<Result<List<GroupMetadata>, GroupMetadataError>> list() async {
    final result = _groups.values.toList()
      ..sort((a, b) => a.groupId.value.compareTo(b.groupId.value));
    return Ok(result);
  }

  @override
  Future<Result<void, GroupMetadataError>> save(GroupMetadata metadata) async {
    _groups[metadata.groupId.value] = metadata;
    return const Ok(null);
  }

  @override
  Future<Result<void, GroupMetadataError>> delete(GroupId groupId) async {
    _groups.remove(groupId.value);
    if (_active == groupId) _active = null;
    return const Ok(null);
  }

  @override
  Future<Result<GroupId?, GroupMetadataError>> loadActiveGroup() async {
    return Ok(_active);
  }

  @override
  Future<Result<void, GroupMetadataError>> saveActiveGroup(
    GroupId? groupId,
  ) async {
    _active = groupId;
    return const Ok(null);
  }
}

// ---------------------------------------------------------------------------
// SyncEngine
// ---------------------------------------------------------------------------

class FakeSyncEngine implements SyncEngine {
  final _changesController = StreamController<void>.broadcast();
  var _synced = false;

  @override
  Future<void> sync() async {
    _synced = true;
    _changesController.add(null);
  }

  @override
  Stream<void> get changes => _changesController.stream;

  bool get synced => _synced;

  @override
  Future<void> close() async => await _changesController.close();
}

// ---------------------------------------------------------------------------
// GroupState
// ---------------------------------------------------------------------------

class FakeGroupState implements IGroupState {
  GroupState _state;
  final _controller = StreamController<GroupState>.broadcast();

  FakeGroupState(this._state);

  @override
  GroupState get state => _state;

  @override
  Stream<GroupState> watch() => _controller.stream;

  void setState(GroupState next) {
    _state = next;
    _controller.add(next);
  }

  Future<void> close() async => await _controller.close();
}

// ---------------------------------------------------------------------------
// SecureKeyStore
// ---------------------------------------------------------------------------

class FakeSecureKeyStore implements SecureKeyStore {
  final _store = <UserId, IdentityBundle>{};
  final _keys = <String, Uint8List>{};

  @override
  Future<Result<void, KeyStoreError>> storeIdentity(
    UserId userId,
    IdentityBundle bundle,
  ) async {
    _store[userId] = bundle;
    return const Ok(null);
  }

  @override
  Future<Result<IdentityBundle, KeyStoreError>> loadIdentity(
    UserId userId,
  ) async {
    final bundle = _store[userId];
    if (bundle == null) {
      return const Err(IdentityNotFound());
    }
    return Ok(bundle);
  }

  @override
  Future<Result<void, KeyStoreError>> deleteIdentity(UserId userId) async {
    _store.remove(userId);
    return const Ok(null);
  }

  @override
  Future<Result<bool, KeyStoreError>> hasIdentity(UserId userId) async =>
      Ok(_store.containsKey(userId));

  @override
  Future<Result<void, KeyStoreError>> storeKey(
    String keyId,
    List<int> bytes,
  ) async {
    _keys[keyId] = Uint8List.fromList(bytes);
    return const Ok(null);
  }

  @override
  Future<Result<List<int>, KeyStoreError>> loadKey(String keyId) async {
    final bytes = _keys[keyId];
    if (bytes == null) {
      return const Err(IdentityNotFound());
    }
    return Ok(Uint8List.fromList(bytes));
  }

  @override
  Future<Result<void, KeyStoreError>> deleteKey(String keyId) async {
    _keys.remove(keyId);
    return const Ok(null);
  }
}

// ---------------------------------------------------------------------------
// ScreenCaptureSource
// ---------------------------------------------------------------------------

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
