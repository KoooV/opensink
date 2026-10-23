import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_peer/core_peer.dart';

/// Настройки fake-соединения.
class FakeRtcBehavior {
  const FakeRtcBehavior({
    this.connectDelay = const Duration(milliseconds: 5),
    this.supportRollback = true,
    this.packetLoss,
    this.artificialRtt = 0.02,
    this.initialSignalingState = RtcSignalingState.stable,
  });

  final Duration connectDelay;
  final bool supportRollback;
  final double? packetLoss;
  final double artificialRtt;

  /// Позволяет воспроизвести native-поведение, когда signalingState не stable
  /// на момент первой навигации (busy-loop regression).
  final RtcSignalingState initialSignalingState;
}

class FakeRtcNetwork {
  final Map<String, FakeRtcPeerConnection> _byId =
      <String, FakeRtcPeerConnection>{};
  final List<FakeRtcPeerConnection> connections = <FakeRtcPeerConnection>[];
  final Random _random = Random(42);

  String register(FakeRtcPeerConnection connection) {
    final id = (_random.nextInt(1 << 30)).toRadixString(36);
    _byId[id] = connection;
    connections.add(connection);
    return id;
  }

  FakeRtcPeerConnection? resolve(String id) => _byId[id];

  List<FakeRtcPeerConnection> get active => connections
      .where(
        (connection) => connection.connectionState != RtcConnectionState.closed,
      )
      .toList(growable: false);
}

class FakeRtcPeerFactory implements RtcPeerFactory {
  FakeRtcPeerFactory({
    FakeRtcNetwork? network,
    this.behavior = const FakeRtcBehavior(),
  }) : network = network ?? FakeRtcNetwork();

  final FakeRtcNetwork network;
  final FakeRtcBehavior behavior;

  @override
  Future<RtcPeerConnection> create(Map<String, dynamic> configuration) async {
    return FakeRtcPeerConnection(network, behavior);
  }
}

class FakeRtcPeerConnection implements RtcPeerConnection {
  FakeRtcPeerConnection(this._network, this._behavior) {
    _signalingState = _behavior.initialSignalingState;
    _id = _network.register(this);
  }

  final FakeRtcNetwork _network;
  final FakeRtcBehavior _behavior;
  late final String _id;

  final StreamController<RtcIceCandidateData> _ice =
      StreamController<RtcIceCandidateData>.broadcast();
  final StreamController<RtcConnectionState> _connectionStates =
      StreamController<RtcConnectionState>.broadcast();
  final StreamController<RtcDataChannel> _dataChannels =
      StreamController<RtcDataChannel>.broadcast();
  final StreamController<void> _negotiationNeeded =
      StreamController<void>.broadcast();

  RtcSignalingState _signalingState = RtcSignalingState.stable;
  RtcConnectionState _connectionState = RtcConnectionState.newState;
  FakeRtcPeerConnection? _offerOrigin;
  final Map<String, FakeRtcDataChannel> _channels =
      <String, FakeRtcDataChannel>{};
  final List<FakeRtcDataChannel> allChannels = <FakeRtcDataChannel>[];
  final Set<String> _processedOffers = <String>{};
  final List<Timer> _timers = <Timer>[];
  int restartIceCount = 0;
  int closeCount = 0;
  double _sentBytes = 0;
  double _receivedBytes = 0;

  String get id => _id;

  FakeRtcDataChannel? channel(String label) => _channels[label];

  void setPacketLoss(double value) {
    // Настройка на уровне теста: подменяет behavior для последующих getStats.
    _packetLossOverride = value;
  }

  double? _packetLossOverride;

  @override
  RtcSignalingState get signalingState => _signalingState;

  @override
  RtcConnectionState get connectionState => _connectionState;

  @override
  Stream<RtcIceCandidateData> get iceCandidates => _ice.stream;

  @override
  Stream<RtcConnectionState> get connectionStates => _connectionStates.stream;

  @override
  Stream<RtcDataChannel> get dataChannels => _dataChannels.stream;

  @override
  Stream<void> get negotiationNeeded => _negotiationNeeded.stream;

  @override
  Future<RtcSessionDescriptionData> createOffer({
    bool iceRestart = false,
  }) async {
    final labels = _channels.keys.join(',');
    return RtcSessionDescriptionData(
      type: 'offer',
      sdp: 'fake-offer:$_id:$labels',
    );
  }

  @override
  Future<RtcSessionDescriptionData> createAnswer() async {
    final origin = _offerOrigin;
    final labels = _channels.keys.join(',');
    return RtcSessionDescriptionData(
      type: 'answer',
      sdp: 'fake-answer:${origin?.id ?? _id}:$_id:$labels',
    );
  }

  @override
  Future<void> setLocalDescription(
    RtcSessionDescriptionData description,
  ) async {
    if (description.type == 'rollback') {
      if (!_behavior.supportRollback) {
        throw StateError('rollback is not supported');
      }
      _signalingState = RtcSignalingState.stable;
      return;
    }
    if (description.type == 'offer') {
      _signalingState = RtcSignalingState.haveLocalOffer;
    } else if (description.type == 'answer') {
      _signalingState = RtcSignalingState.stable;
      _scheduleConnected();
    }
  }

  @override
  Future<void> setRemoteDescription(
    RtcSessionDescriptionData description,
  ) async {
    if (description.type == 'offer') {
      _signalingState = RtcSignalingState.haveRemoteOffer;
      _attachOffer(description.sdp);
    } else if (description.type == 'answer') {
      _signalingState = RtcSignalingState.stable;
      _attachAnswer(description.sdp);
      _scheduleConnected();
    }
  }

  void _attachAnswer(String sdp) {
    final parts = sdp.split(':');
    if (parts.length < 3 || parts.first != 'fake-answer') {
      return;
    }
    final answerer = _network.resolve(parts[2]);
    if (answerer == null || answerer == this) {
      return;
    }
    final labels = parts.length > 3 && parts[3].isNotEmpty
        ? parts[3].split(',')
        : const <String>[];
    for (final label in labels) {
      final answererChannel = answerer._channels[label];
      if (answererChannel == null) {
        continue;
      }
      final remoteChannel = FakeRtcDataChannel(
        label,
        connection: this,
        ordered: answererChannel.ordered,
        maxRetransmits: answererChannel.maxRetransmits,
      );
      _channels.putIfAbsent(label, () => remoteChannel);
      allChannels.add(remoteChannel);
      answererChannel.pairWith(remoteChannel);
      remoteChannel.pairWith(answererChannel);
      if (answererChannel.state == RtcDataChannelState.open) {
        remoteChannel.open();
      }
      _dataChannels.add(remoteChannel);
    }
  }

  void _attachOffer(String sdp) {
    final parts = sdp.split(':');
    if (parts.length < 2 || parts.first != 'fake-offer') {
      return;
    }
    if (!_processedOffers.add(parts[1])) {
      return;
    }
    final origin = _network.resolve(parts[1]);
    if (origin == null) {
      return;
    }
    _offerOrigin = origin;
    final labels = parts.length > 2 && parts[2].isNotEmpty
        ? parts[2].split(',')
        : const <String>[];
    for (final label in labels) {
      final originChannel = origin._channels[label];
      if (originChannel == null) {
        continue;
      }
      final remoteChannel = FakeRtcDataChannel(
        label,
        connection: this,
        ordered: originChannel.ordered,
        maxRetransmits: originChannel.maxRetransmits,
      );
      _channels.putIfAbsent(label, () => remoteChannel);
      allChannels.add(remoteChannel);
      originChannel.pairWith(remoteChannel);
      remoteChannel.pairWith(originChannel);
      if (originChannel.state == RtcDataChannelState.open) {
        remoteChannel.open();
      }
      _dataChannels.add(remoteChannel);
    }
  }

  @override
  Future<void> addIceCandidate(RtcIceCandidateData candidate) async {}

  @override
  Future<void> restartIce() async {
    restartIceCount++;
  }

  @override
  Future<void> close() async {
    if (_connectionState == RtcConnectionState.closed) {
      return;
    }
    closeCount++;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _connectionState = RtcConnectionState.closed;
    _signalingState = RtcSignalingState.closed;
    _connectionStates.add(_connectionState);
    for (final channel in List<FakeRtcDataChannel>.of(_channels.values)) {
      channel.markClosed();
    }
    await _ice.close();
    await _connectionStates.close();
    await _dataChannels.close();
    await _negotiationNeeded.close();
  }

  @override
  Future<List<RtcStats>> getStats() async {
    return <RtcStats>[
      RtcStats(
        id: 'pair',
        type: 'candidate-pair',
        values: <String, Object?>{
          'state': 'succeeded',
          'nominated': true,
          'currentRoundTripTime': _behavior.artificialRtt,
          'bytesSent': _sentBytes.toInt(),
          'bytesReceived': _receivedBytes.toInt(),
        },
      ),
      if ((_packetLossOverride ?? _behavior.packetLoss) != null)
        RtcStats(
          id: 'remote-inbound',
          type: 'remote-inbound-rtp',
          values: <String, Object?>{
            'packetsLost':
                ((_packetLossOverride ?? _behavior.packetLoss)! * 1000).round(),
            'packetsReceived': 1000,
          },
        ),
    ];
  }

  @override
  Future<RtcDataChannel> createDataChannel(
    String label, {
    required bool ordered,
    int? maxRetransmits,
  }) async {
    final channel = FakeRtcDataChannel(
      label,
      connection: this,
      ordered: ordered,
      maxRetransmits: maxRetransmits,
    );
    _channels[label] = channel;
    allChannels.add(channel);
    if (_connectionState == RtcConnectionState.connected) {
      channel.open();
    }
    return channel;
  }

  void _scheduleConnected() {
    _timers.add(
      Timer(_behavior.connectDelay, () {
        if (_connectionState == RtcConnectionState.closed) {
          return;
        }
        _connectionState = RtcConnectionState.connected;
        _connectionStates.add(_connectionState);
        final all = List<FakeRtcDataChannel>.of(_channels.values);
        for (final channel in all) {
          channel.open();
        }
      }),
    );
  }

  void simulateDisconnected() {
    if (_connectionState == RtcConnectionState.closed) {
      return;
    }
    _connectionState = RtcConnectionState.disconnected;
    _connectionStates.add(_connectionState);
  }

  void simulateFailure() {
    if (_connectionState == RtcConnectionState.closed) {
      return;
    }
    _connectionState = RtcConnectionState.failed;
    _connectionStates.add(_connectionState);
  }

  void simulateRestored() {
    if (_connectionState == RtcConnectionState.closed) {
      return;
    }
    _connectionState = RtcConnectionState.connected;
    _connectionStates.add(_connectionState);
    for (final channel in _channels.values) {
      channel.open();
    }
  }

  void recordSent(int bytes) {
    _sentBytes += bytes;
  }

  void recordReceived(int bytes) {
    _receivedBytes += bytes;
  }
}

class FakeRtcDataChannel implements RtcDataChannel {
  FakeRtcDataChannel(
    this.label, {
    required this.connection,
    required this.ordered,
    required this.maxRetransmits,
  });

  @override
  final String label;
  final FakeRtcPeerConnection connection;
  final bool ordered;
  final int? maxRetransmits;

  final StreamController<RtcDataChannelState> _states =
      StreamController<RtcDataChannelState>.broadcast();
  final StreamController<List<int>> _messages =
      StreamController<List<int>>.broadcast();
  final StreamController<void> _bufferedLow =
      StreamController<void>.broadcast();

  RtcDataChannelState _state = RtcDataChannelState.connecting;
  int _bufferedAmount = 0;
  int _lowThreshold = 256 * 1024;
  FakeRtcDataChannel? _peer;
  final List<List<int>> _blocked = <List<int>>[];

  /// Если false, send накапливает bufferedAmount и не доставляет данные.
  bool autoDrain = true;

  @override
  RtcDataChannelState get state => _state;

  @override
  int get bufferedAmount => _bufferedAmount;

  @override
  Stream<RtcDataChannelState> get states => _states.stream;

  @override
  Stream<List<int>> get messages => _messages.stream;

  @override
  Stream<void> get bufferedAmountLow => _bufferedLow.stream;

  void pairWith(FakeRtcDataChannel peer) {
    _peer = peer;
  }

  void open() {
    if (_state == RtcDataChannelState.open ||
        _state == RtcDataChannelState.closed) {
      return;
    }
    _state = RtcDataChannelState.open;
    _states.add(_state);
    _peer?.open();
  }

  void markClosed() {
    if (_state == RtcDataChannelState.closed) {
      return;
    }
    _state = RtcDataChannelState.closed;
    _states.add(_state);
    unawaited(_states.close());
    unawaited(_messages.close());
    unawaited(_bufferedLow.close());
  }

  @override
  Future<void> setBufferedAmountLowThreshold(int bytes) async {
    _lowThreshold = bytes;
  }

  @override
  Future<void> send(List<int> bytes) async {
    if (_state != RtcDataChannelState.open) {
      throw StateError('data channel is not open');
    }
    connection.recordSent(bytes.length);
    if (autoDrain) {
      _deliver(bytes);
      return;
    }
    _blocked.add(List<int>.of(bytes));
    _bufferedAmount += bytes.length;
    if (_bufferedAmount <= _lowThreshold && !_bufferedLow.isClosed) {
      _bufferedLow.add(null);
    }
  }

  /// Доставляет накопленные сообщения и опускает bufferedAmount до нуля.
  void drain() {
    final blocked = List<List<int>>.of(_blocked);
    _blocked.clear();
    _bufferedAmount = 0;
    for (final bytes in blocked) {
      _deliver(bytes);
    }
    if (!_bufferedLow.isClosed) {
      _bufferedLow.add(null);
    }
  }

  void _deliver(List<int> bytes) {
    final peer = _peer;
    if (peer == null || peer._state != RtcDataChannelState.open) {
      return;
    }
    peer.connection.recordReceived(bytes.length);
    if (!peer._messages.isClosed) {
      peer._messages.add(Uint8List.fromList(bytes));
    }
  }

  @override
  Future<void> close() async {
    markClosed();
  }
}
