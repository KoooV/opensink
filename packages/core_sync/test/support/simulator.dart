import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';

import 'ed25519_identity.dart';
import 'memory_store.dart';

class SimulatedNetwork {
  SimulatedNetwork(this.random);

  final Random random;
  final Map<String, StreamController<Uint8List>> _incoming = {};
  final List<_Packet> _queue = [];
  final Set<String> _partitions = {};

  double loss = 0;
  int sent = 0;
  int dropped = 0;

  int get queueLength => _queue.length;

  void register(int from, int to, StreamController<Uint8List> incoming) {
    _incoming['$from->$to'] = incoming;
  }

  void setPartition(int a, int b, {required bool partitioned}) {
    final key = a < b ? '$a-$b' : '$b-$a';
    if (partitioned) {
      _partitions.add(key);
    } else {
      _partitions.remove(key);
    }
  }

  bool isPartitioned(int a, int b) {
    final key = a < b ? '$a-$b' : '$b-$a';
    return _partitions.contains(key);
  }

  void clearPartitions() => _partitions.clear();

  void send(int from, int to, Uint8List bytes) {
    sent++;
    if (isPartitioned(from, to) || random.nextDouble() < loss) {
      dropped++;
      return;
    }
    _queue.add(_Packet(from, to, bytes));
  }

  Future<void> flush() async {
    if (_queue.isEmpty) return;
    final batch = List<_Packet>.from(_queue);
    _queue.clear();
    batch.shuffle(random);
    for (final packet in batch) {
      // ignore: close_sinks
      final controller = _incoming['${packet.from}->${packet.to}'];
      if (controller == null || controller.isClosed) continue;
      controller.add(packet.bytes);
    }
    await Future<void>.delayed(Duration.zero);
  }
}

class _Packet {
  _Packet(this.from, this.to, this.bytes);
  final int from;
  final int to;
  final Uint8List bytes;
}

class SimulatedLink implements SyncLink {
  SimulatedLink({
    required this.network,
    required this.from,
    required this.to,
    required this.peerId,
  }) {
    // Входящий контроллер этого линка принимает пакеты от remote (to)
    // к локальному узлу (from), поэтому ключ обратный направлению send.
    network.register(to, from, _incoming);
  }

  final SimulatedNetwork network;
  final int from;
  final int to;

  @override
  final String peerId;

  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) async {
    network.send(from, to, bytes);
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

class FakeTime {
  int value = 1700000000000;
  void advance(int ms) => value += ms;
}

class SimulatedNode {
  SimulatedNode({
    required this.index,
    required this.author,
    required this.store,
    required this.engine,
  });

  final int index;
  final UserId author;
  final MemorySyncEventStore store;
  final SyncEngineImpl engine;
  final List<EventId> ownMessages = [];

  int get eventCount => store.length;
}

class SyncSimulator {
  SyncSimulator({
    required this.seed,
    this.replicas = 3,
    this.priorityWindow = 8,
    this.maxBatchSize = 4,
  }) : _random = Random(seed);

  final int seed;
  final int replicas;
  final int priorityWindow;
  final int maxBatchSize;

  final Random _random;
  final FakeTime _time = FakeTime();
  late final SimulatedNetwork network = SimulatedNetwork(_random);
  final List<SimulatedNode> nodes = [];
  final GroupId groupId = const GroupId('group-1');
  final ChannelId channelId = const ChannelId('channel-1');

  Future<void> setup() async {
    for (var i = 0; i < replicas; i++) {
      final identity = await Ed25519Identity.create(i);
      final author = identity.author;
      final store = MemorySyncEventStore();
      final clock = HlcClock(
        nowMs: () => _time.value + i * 7,
        initial: Hlc(_time.value + i * 7, 0),
      );
      final engine = SyncEngineImpl(
        store: store,
        signer: identity.signer,
        localAuthor: author,
        clock: clock,
        nowMs: () => _time.value + i * 7,
        priorityWindow: priorityWindow,
        maxBatchSize: maxBatchSize,
        maxGossipHops: 4,
      );
      nodes.add(
        SimulatedNode(index: i, author: author, store: store, engine: engine),
      );
    }

    for (var from = 0; from < replicas; from++) {
      for (var to = 0; to < replicas; to++) {
        if (from == to) continue;
        await nodes[from].engine.attach(
          SimulatedLink(
            network: network,
            from: from,
            to: to,
            peerId: nodes[to].author.value,
          ),
        );
      }
    }

    for (final node in nodes) {
      await node.engine.registerGroup(groupId);
    }
    await pump();

    final created = await nodes.first.engine.createGroup(groupId);
    if (created.isErr) {
      throw StateError('group create failed: ${created.unwrapErr()}');
    }
    await pump();

    for (var i = 1; i < replicas; i++) {
      final added = await nodes.first.engine.addMember(
        groupId,
        nodes[i].author,
      );
      if (added.isErr) {
        throw StateError('add member failed: ${added.unwrapErr()}');
      }
    }
    await pump();
    await reconcileAll();

    final channel = await nodes.first.engine.createChannel(
      groupId,
      channelId,
      name: 'general',
    );
    if (channel.isErr) {
      throw StateError('channel create failed: ${channel.unwrapErr()}');
    }
    await pump();
    await reconcileAll();
  }

  Future<void> pump({int maxIterations = 200}) async {
    for (var i = 0; i < maxIterations; i++) {
      final hadPackets = network.queueLength;
      await network.flush();
      await Future.wait(nodes.map((node) => node.engine.drain()));
      await Future<void>.delayed(Duration.zero);
      if (network.queueLength == 0 && hadPackets == 0) return;
    }
    throw StateError('simulated network did not settle for seed $seed');
  }

  Future<void> reconcileAll() async {
    for (final node in nodes) {
      await node.engine.runAntiEntropy();
    }
    await pump();
  }

  /// Явный запрос истории, моделирующий действие UI (прокрутка/открытие канала).
  Future<void> requestFullHistory() async {
    for (final node in nodes) {
      await node.engine.requestHistory(groupId);
    }
    await pump();
  }

  Future<void> runChaos({int rounds = 8}) async {
    for (var round = 0; round < rounds; round++) {
      _togglePartitions();
      network.loss = _random.nextInt(5) == 0 ? 0.15 : 0;
      final operations = 1 + _random.nextInt(3);
      for (var i = 0; i < operations; i++) {
        _time.advance(100 + _random.nextInt(50));
        await _randomOperation();
      }
      await pump();
      if (_random.nextBool()) {
        await nodes[_random.nextInt(nodes.length)].engine.runAntiEntropy();
        await pump();
      }
    }
  }

  void _togglePartitions() {
    for (var a = 0; a < replicas; a++) {
      for (var b = a + 1; b < replicas; b++) {
        if (_random.nextDouble() < 0.3) {
          network.setPartition(a, b, partitioned: !network.isPartitioned(a, b));
        }
      }
    }
  }

  Future<void> _randomOperation() async {
    final node = nodes[_random.nextInt(nodes.length)];
    final roll = _random.nextInt(100);
    if (roll < 55 || node.ownMessages.isEmpty) {
      final text = 'm${_time.value}-${node.index}-${_random.nextInt(1000)}';
      final result = await node.engine.postMessage(groupId, channelId, text);
      if (result.isOk) node.ownMessages.add(result.unwrap().id);
      return;
    }
    if (roll < 80) {
      final target = node.ownMessages[_random.nextInt(node.ownMessages.length)];
      await node.engine.editMessage(
        groupId,
        channelId,
        target,
        'edit-${_time.value}-${node.index}',
      );
      return;
    }
    if (roll < 95) {
      final target = node.ownMessages[_random.nextInt(node.ownMessages.length)];
      await node.engine.deleteMessage(groupId, channelId, target);
      return;
    }
    await node.engine.renameGroup(groupId, 'group-${_time.value}');
  }

  Future<void> healAndConverge({int maxRounds = 20}) async {
    network.clearPartitions();
    network.loss = 0;
    await requestFullHistory();
    for (var round = 0; round < maxRounds; round++) {
      await reconcileAll();
      if (await _converged()) return;
    }
    if (!await _converged()) {
      throw StateError(
        'no convergence for seed $seed: '
        '${nodes.map((node) => node.eventCount).toList()}',
      );
    }
  }

  Future<bool> _converged() async {
    final reference = (await nodes.first.engine.allEvents(groupId))
        .map((event) => event.id.value)
        .toSet();
    for (var i = 1; i < nodes.length; i++) {
      final other = (await nodes[i].engine.allEvents(groupId))
          .map((event) => event.id.value)
          .toSet();
      if (other.length != reference.length || !other.containsAll(reference)) {
        return false;
      }
    }
    return true;
  }

  Future<void> verifyConvergence() async {
    final eventSets = <Set<String>>[];
    final projections = <GroupProjection>[];
    for (final node in nodes) {
      final events = await node.engine.allEvents(groupId);
      eventSets.add(events.map((event) => event.id.value).toSet());
      projections.add(await node.engine.projection(groupId));
    }
    for (var i = 1; i < eventSets.length; i++) {
      if (eventSets[i].length != eventSets[0].length ||
          !eventSets[i].containsAll(eventSets[0])) {
        throw StateError(
          'event sets diverged for seed $seed: '
          '${nodes.map((node) => node.eventCount).toList()}',
        );
      }
      if (projections[i] != projections[0]) {
        throw StateError('projections diverged for seed $seed');
      }
    }
  }

  Future<void> close() async {
    for (final node in nodes) {
      await node.engine.close();
    }
  }
}
