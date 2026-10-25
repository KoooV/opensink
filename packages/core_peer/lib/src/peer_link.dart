import 'dart:async';
import 'dart:math';

// ignore_for_file: prefer_initializing_formals

import 'package:core_domain/core_domain.dart';

import 'config.dart';
import 'errors.dart';
import 'rtc/rtc_types.dart';
import 'signaling/peer_signal.dart';

/// Прямая WebRTC-ссылка с одним peer.
///
/// Ссылка переживает пересоздание PeerConnection: наружу отдаются одни и те же
/// [stateStream]/[incoming], а внутренняя реализация может переподключаться.
class WebRtcPeerLink implements PeerLink {
  WebRtcPeerLink({
    required this.localPeerId,
    required this.remotePeerId,
    required this.topic,
    required RtcPeerFactory factory,
    required PeerConnectionConfig config,
    required Future<void> Function(PeerSignal signal) publishSignal,
    required bool initiate,
    Random? random,
  }) : _factory = factory,
       _config = config,
       _publishSignal = publishSignal,
       _initiatesChannels = initiate,
       _random = random ?? Random(),
       _isPolite = comparePeerIds(localPeerId, remotePeerId) < 0 {
    // Для passive-ссылки waitUntilConnected может не вызываться; ошибка
    // закрытия не должна становиться unhandled.
    unawaited(_ready.future.catchError((Object _) {}));
  }

  final PeerId localPeerId;
  @override
  final PeerId remotePeerId;
  final String topic;

  final RtcPeerFactory _factory;
  final PeerConnectionConfig _config;
  final Future<void> Function(PeerSignal signal) _publishSignal;
  final bool _initiatesChannels;
  final Random _random;
  final bool _isPolite;

  final StreamController<Incoming> _incoming =
      StreamController<Incoming>.broadcast();
  final StreamController<PeerLinkState> _stateChanges =
      StreamController<PeerLinkState>.broadcast();
  final Completer<void> _ready = Completer<void>();

  PeerLinkState _state = PeerLinkState.connecting;
  PeerLinkStats _stats = const PeerLinkStats(
    rtt: Duration.zero,
    bytesSent: 0,
    bytesReceived: 0,
    loss: 0,
  );

  RtcPeerConnection? _pc;
  final Map<String, RtcDataChannel> _channels = <String, RtcDataChannel>{};
  final Map<String, List<Completer<RtcDataChannel>>> _openWaiters =
      <String, List<Completer<RtcDataChannel>>>{};
  final Map<String, _ChannelQueue> _sendQueues = <String, _ChannelQueue>{};
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  final List<RtcIceCandidateData> _pendingRemoteCandidates =
      <RtcIceCandidateData>[];

  bool _closed = false;
  bool _remoteClosed = false;
  bool _shouldOffer = false;
  bool _initializing = false;
  bool _makingOffer = false;
  bool _answeringOffer = false;
  bool _ignoreOffer = false;
  bool _remoteDescriptionSet = false;
  bool _needsNegotiation = false;
  bool _iceRestartRequested = false;
  bool _resetCycleActive = false;
  bool _resetOfferPending = false;
  int _lastResetSession = 0;
  Future<void>? _negotiationInFlight;

  int _sessionCounter = 0;
  int _localSession = 0;
  int _negotiationSession = 0;
  int _lastRemoteOfferSession = 0;
  int _reconnectAttempt = 0;
  int _sentBytes = 0;
  int _receivedBytes = 0;
  int _lastStatsBytesSent = 0;
  DateTime? _lastStatsAt;

  Timer? _connectTimer;
  Timer? _disconnectedTimer;
  Timer? _iceRestartTimer;
  Timer? _reconnectTimer;
  Timer? _statsTimer;

  bool get isPolite => _isPolite;

  bool get isClosed => _closed;

  @override
  Stream<PeerLinkState> get stateStream => _stateChanges.stream;

  @override
  Stream<Incoming> get incoming => _incoming.stream;

  @override
  PeerLinkState get state => _state;

  @override
  PeerLinkStats get stats => _stats;

  /// Запускает PeerConnection. Для инициатора сразу отправляет offer.
  Future<void> start() async {
    if (_closed) {
      throw const PeerClosed();
    }
    _sessionCounter = _random.nextInt(1 << 31);
    _initializing = true;
    try {
      await _openConnection(createChannels: _initiatesChannels);
    } finally {
      _initializing = false;
    }
    _armConnectTimeout();
    if (_initiatesChannels) {
      _scheduleNegotiation();
    }
  }

  /// Завершается, когда peer connection и control-канал открыты.
  Future<void> waitUntilConnected() {
    if (_state == PeerLinkState.connected && _isControlOpen) {
      return Future<void>.value();
    }
    return _ready.future.timeout(
      _config.connectTimeout,
      onTimeout: () => throw const PeerConnectTimeout(),
    );
  }

  /// Обрабатывает сигнал, полученный через слой 5.
  Future<void> handleSignal(PeerSignal signal) async {
    if (_closed) {
      return;
    }
    switch (signal.kind) {
      case PeerSignalKind.offer:
        await _handleOffer(signal);
      case PeerSignalKind.answer:
        await _handleAnswer(signal);
      case PeerSignalKind.ice:
        await _handleIce(signal);
      case PeerSignalKind.hangup:
        await _closeFromRemote();
    }
  }

  /// ICE restart при смене сети.
  Future<void> onNetworkChanged() async {
    if (_closed || _pc == null) {
      return;
    }
    _reconnectAttempt = 0;
    await restartIce();
  }

  /// Перезапускает ICE без пересоздания каналов.
  Future<void> restartIce() async {
    final pc = _pc;
    if (_closed || pc == null) {
      return;
    }
    _cancel(_disconnectedTimer);
    _disconnectedTimer = null;
    _setState(PeerLinkState.connecting);
    _armIceRestartTimeout();
    try {
      await pc.restartIce();
    } catch (_) {
      _scheduleReconnect(immediate: true);
      return;
    }
    _scheduleNegotiation(iceRestart: true);
  }

  @override
  Future<void> send(String channel, List<int> bytes) {
    if (_closed) {
      return Future<void>.error(const PeerClosed());
    }
    if (bytes.length > _config.maxMessageBytes) {
      return Future<void>.error(
        ArgumentError.value(
          bytes.length,
          'bytes',
          'message exceeds maxMessageBytes',
        ),
      );
    }
    final queue = _sendQueues.putIfAbsent(channel, _ChannelQueue.new);
    return queue.run(() async {
      for (var attempt = 0; attempt < 2; attempt++) {
        final dataChannel = await _awaitOpenChannel(channel);
        if (channel == PeerChannels.file &&
            dataChannel.bufferedAmount > _config.bufferedAmountHighWater) {
          await _waitForBuffer(dataChannel);
        }
        try {
          await dataChannel.send(bytes);
          _sentBytes += bytes.length;
          return;
        } catch (_) {
          // Канал мог быть заменён при glare/reset между await и send.
          if (attempt == 0 && dataChannel.state == RtcDataChannelState.closed) {
            continue;
          }
          rethrow;
        }
      }
    });
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    final session = _negotiationSession != 0
        ? _negotiationSession
        : _localSession;
    if (!_remoteClosed) {
      try {
        await _publishSignal(PeerSignal.hangup(session: session))
            .timeout(const Duration(seconds: 1));
      } catch (_) {
        // Сигнализация может быть уже закрыта; локальное закрытие важнее.
      }
    }
    await _shutdown(remote: false);
  }

  Future<void> _openConnection({required bool createChannels}) async {
    if (_closed) {
      return;
    }
    final pc = await _factory.create(_config.toRtcConfiguration());
    if (_closed) {
      await pc.close();
      return;
    }
    _pc = pc;
    _remoteDescriptionSet = false;
    _pendingRemoteCandidates.clear();
    _ignoreOffer = false;

    _subscriptions.add(pc.iceCandidates.listen(_onLocalIceCandidate));
    _subscriptions.add(pc.connectionStates.listen(_onConnectionState));
    _subscriptions.add(pc.dataChannels.listen(_onRemoteChannel));
    _subscriptions.add(
      pc.negotiationNeeded.listen((_) {
        if (_shouldOffer && !_initializing) {
          _scheduleNegotiation();
        }
      }),
    );

    if (createChannels) {
      _shouldOffer = true;
      await _createLocalChannels(pc);
    }
  }

  Future<void> _createLocalChannels(RtcPeerConnection pc) async {
    await _createChannel(pc, PeerChannels.control, ordered: true);
    await _createChannel(pc, PeerChannels.sync, ordered: true);
    await _createChannel(pc, PeerChannels.file, ordered: true);
    await _createChannel(pc, PeerChannels.relay, ordered: true);
    if (_config.enableUnreliablePresence) {
      await _createChannel(
        pc,
        PeerChannels.presence,
        ordered: false,
        maxRetransmits: 0,
      );
    }
  }

  Future<void> _createChannel(
    RtcPeerConnection pc,
    String label, {
    required bool ordered,
    int? maxRetransmits,
  }) async {
    final channel = await pc.createDataChannel(
      label,
      ordered: ordered,
      maxRetransmits: maxRetransmits,
    );
    _bindChannel(channel);
  }

  void _onRemoteChannel(RtcDataChannel channel) {
    final existing = _channels[channel.label];
    if (existing != null && !identical(existing, channel)) {
      // Оба пира создали канал с одинаковым label (одновременный connect).
      // Impolite оставляет свой открытый канал, polite — канал impolite-пира.
      // Закрытый локальный канал заменяется в любом случае.
      if (!_isPolite && existing.state != RtcDataChannelState.closed) {
        unawaited(channel.close());
        return;
      }
      _unbindChannel(existing, close: true);
    }
    _bindChannel(channel);
  }

  void _bindChannel(RtcDataChannel channel) {
    _channels[channel.label] = channel;
    if (channel.label == PeerChannels.file) {
      unawaited(
        channel.setBufferedAmountLowThreshold(
          _config.bufferedAmountLowThreshold,
        ),
      );
    }
    _subscriptions.add(
      channel.messages.listen((bytes) {
        _receivedBytes += bytes.length;
        if (!_incoming.isClosed) {
          _incoming.add(
            Incoming(
              channel: channel.label,
              bytes: bytes,
              timestamp: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        }
      }),
    );
    _subscriptions.add(
      channel.states.listen((state) {
        if (state == RtcDataChannelState.open) {
          _completeOpenWaiters(channel.label, channel);
          _maybeCompleteReady();
        } else if (state == RtcDataChannelState.closed) {
          if (identical(_channels[channel.label], channel)) {
            _channels.remove(channel.label);
          }
          _failOpenWaiters(channel.label);
        }
      }),
    );
    if (channel.state == RtcDataChannelState.open) {
      _completeOpenWaiters(channel.label, channel);
      _maybeCompleteReady();
    }
  }

  void _unbindChannel(RtcDataChannel channel, {required bool close}) {
    _channels.remove(channel.label);
    _failOpenWaiters(channel.label);
    if (close) {
      unawaited(channel.close());
    }
  }

  void _completeOpenWaiters(String label, RtcDataChannel channel) {
    final waiters = _openWaiters.remove(label);
    if (waiters == null) {
      return;
    }
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(channel);
      }
    }
  }

  void _failOpenWaiters(String label) {
    final waiters = _openWaiters.remove(label);
    if (waiters == null) {
      return;
    }
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(PeerChannelUnavailable(label));
      }
    }
  }

  bool get _isControlOpen =>
      _channels[PeerChannels.control]?.state == RtcDataChannelState.open;

  void _maybeCompleteReady() {
    if (!_ready.isCompleted &&
        _state == PeerLinkState.connected &&
        _isControlOpen) {
      _ready.complete();
    }
  }

  Future<void> _handleOffer(PeerSignal signal) async {
    final pc = _pc;
    if (pc == null || signal.sdp == null) {
      return;
    }
    if (signal.session == _lastRemoteOfferSession) {
      return;
    }
    _lastRemoteOfferSession = signal.session;
    final description = RtcSessionDescriptionData(
      type: 'offer',
      sdp: signal.sdp!,
    );
    final collision =
        _makingOffer || pc.signalingState != RtcSignalingState.stable;
    final ignore = !_isPolite && collision;
    _ignoreOffer = ignore;
    if (ignore) {
      return;
    }

    if (signal.reset && signal.session != _lastResetSession) {
      final inFlight = _negotiationInFlight;
      if (inFlight != null) {
        try {
          await inFlight;
        } catch (_) {
          // Собственная навигация уже завершилась ошибкой.
        }
      }
      _lastResetSession = signal.session;
      _initializing = true;
      try {
        await _disposeConnection();
        // Reset-offer создаёт каналы; отвечающая сторона их принимает.
        await _openConnection(createChannels: false);
      } finally {
        _initializing = false;
      }
      final fresh = _pc;
      if (fresh == null) {
        return;
      }
      _ignoreOffer = false;
      _resetCycleActive = true;
      _armConnectTimeout();
      // Remote уже выполнил reset. Свои отложенные reset/negotiation больше
      // не нужны, иначе обе стороны могут бесконечно пересоздавать PC.
      _resetOfferPending = false;
      _iceRestartRequested = false;
      _needsNegotiation = false;
      await _applyRemoteOffer(fresh, description, signal.session);
      return;
    }

    if (collision) {
      final inFlight = _negotiationInFlight;
      if (inFlight != null) {
        try {
          await inFlight;
        } catch (_) {
          // Ошибка собственной навигации не должна блокировать ответ.
        }
      }
      if (_pc != pc) {
        return;
      }
      if (pc.signalingState != RtcSignalingState.stable) {
        try {
          await pc.setLocalDescription(
            const RtcSessionDescriptionData.rollback(),
          );
        } catch (_) {
          await _recreateForGlare(description, signal.session);
          return;
        }
      }
    }

    _ignoreOffer = false;
    await _applyRemoteOffer(pc, description, signal.session);
  }

  Future<void> _applyRemoteOffer(
    RtcPeerConnection pc,
    RtcSessionDescriptionData description,
    int session,
  ) async {
    try {
      await pc.setRemoteDescription(description);
      _remoteDescriptionSet = true;
      _negotiationSession = session;
      await _drainRemoteCandidates();
      _answeringOffer = true;
      final answer = await pc.createAnswer();
      if (_closed || _pc != pc) {
        return;
      }
      await pc.setLocalDescription(answer);
      await _publishSignal(
        PeerSignal.answer(session: session, sdp: answer.sdp),
      );
    } catch (_) {
      if (!_closed) {
        _scheduleReconnect();
      }
    } finally {
      _answeringOffer = false;
      if (_needsNegotiation && _shouldOffer && !_closed) {
        _needsNegotiation = false;
        _scheduleNegotiation();
      }
    }
  }

  Future<void> _recreateForGlare(
    RtcSessionDescriptionData description,
    int session,
  ) async {
    _initializing = true;
    try {
      await _disposeConnection();
      await _openConnection(createChannels: false);
    } finally {
      _initializing = false;
    }
    final pc = _pc;
    if (pc == null) {
      return;
    }
    await _applyRemoteOffer(pc, description, session);
  }

  Future<void> _handleAnswer(PeerSignal signal) async {
    final pc = _pc;
    if (pc == null || signal.sdp == null || signal.session != _localSession) {
      return;
    }
    if (pc.signalingState != RtcSignalingState.haveLocalOffer) {
      return;
    }
    try {
      await pc.setRemoteDescription(
        RtcSessionDescriptionData(type: 'answer', sdp: signal.sdp!),
      );
      _remoteDescriptionSet = true;
      _negotiationSession = signal.session;
      _ignoreOffer = false;
      await _drainRemoteCandidates();
      if (_needsNegotiation && _shouldOffer && !_closed) {
        _needsNegotiation = false;
        _scheduleNegotiation();
      }
    } catch (_) {
      if (!_closed) {
        _scheduleReconnect();
      }
    }
  }

  Future<void> _handleIce(PeerSignal signal) async {
    if (_ignoreOffer) {
      return;
    }
    if (signal.session != 0 &&
        _negotiationSession != 0 &&
        signal.session != _negotiationSession) {
      return;
    }
    final candidate = RtcIceCandidateData(
      candidate: signal.candidate ?? '',
      sdpMid: signal.sdpMid,
      sdpMLineIndex: signal.sdpMLineIndex,
    );
    if (candidate.candidate.isEmpty) {
      return;
    }
    final pc = _pc;
    if (pc == null || !_remoteDescriptionSet) {
      if (_pendingRemoteCandidates.length < 256) {
        _pendingRemoteCandidates.add(candidate);
      }
      return;
    }
    try {
      await pc.addIceCandidate(candidate);
    } catch (_) {
      // Кандидат мог устареть после ICE restart; не роняем соединение.
    }
  }

  Future<void> _drainRemoteCandidates() async {
    final pc = _pc;
    if (pc == null) {
      return;
    }
    final pending = List<RtcIceCandidateData>.of(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidate in pending) {
      try {
        await pc.addIceCandidate(candidate);
      } catch (_) {
        // Устаревший кандидат.
      }
    }
  }

  void _onLocalIceCandidate(RtcIceCandidateData candidate) {
    if (_closed || _pc == null) {
      return;
    }
    final session = _negotiationSession != 0
        ? _negotiationSession
        : _localSession;
    unawaited(
      _publishSignal(
        PeerSignal.ice(
          session: session,
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      ).catchError((_) {
        // Ошибка публикации обрабатывается таймаутом соединения.
      }),
    );
  }

  void _onConnectionState(RtcConnectionState state) {
    if (_closed) {
      return;
    }
    switch (state) {
      case RtcConnectionState.connected:
        _handleConnected();
      case RtcConnectionState.disconnected:
        _handleDisconnected();
      case RtcConnectionState.failed:
        _scheduleReconnect();
      case RtcConnectionState.closed:
        if (!_closed) {
          _scheduleReconnect();
        }
      case RtcConnectionState.newState:
      case RtcConnectionState.connecting:
        break;
    }
  }

  void _handleConnected() {
    _cancel(_disconnectedTimer);
    _disconnectedTimer = null;
    _cancel(_iceRestartTimer);
    _iceRestartTimer = null;
    _cancel(_connectTimer);
    _connectTimer = null;
    _reconnectAttempt = 0;
    _resetCycleActive = false;
    _setState(PeerLinkState.connected);
    _maybeCompleteReady();
    _startStats();
  }

  void _handleDisconnected() {
    if (_state == PeerLinkState.connected) {
      _setState(PeerLinkState.connecting);
    }
    _disconnectedTimer ??= Timer(_config.disconnectedGrace, () {
      _disconnectedTimer = null;
      if (!_closed && _state != PeerLinkState.connected) {
        unawaited(restartIce());
      }
    });
  }

  void _scheduleNegotiation({bool iceRestart = false}) {
    if (_closed || _pc == null) {
      return;
    }
    if (_state == PeerLinkState.connected && !iceRestart) {
      // После установления соединения negotiationneeded от платформы может
      // приходить повторно; новые изменения запрашиваются явно.
      return;
    }
    if (_answeringOffer) {
      if (_shouldOffer) {
        _needsNegotiation = true;
      }
      if (iceRestart) {
        _iceRestartRequested = true;
      }
      return;
    }
    if (iceRestart) {
      _iceRestartRequested = true;
    }
    if (_negotiationInFlight != null) {
      _needsNegotiation = true;
      return;
    }
    _negotiationInFlight = _runNegotiation();
    unawaited(
      _negotiationInFlight!
          .whenComplete(() {
            _negotiationInFlight = null;
            if (_closed) {
              _needsNegotiation = false;
              return;
            }
            if (!_needsNegotiation) {
              return;
            }
            final pc = _pc;
            // Пока есть незавершённый offer/answer, повторный запуск
            // навигации невозможен. Флаг сохраняется и будет обработан
            // после answer или чужого offer — без busy-loop.
            final canNegotiate =
                pc != null &&
                !_answeringOffer &&
                pc.signalingState == RtcSignalingState.stable &&
                (_state != PeerLinkState.connected || _iceRestartRequested);
            if (canNegotiate) {
              _needsNegotiation = false;
              _scheduleNegotiation();
            }
          })
          .catchError((Object _) {
            // Ошибки навигации уже обработаны/приведут к reconnect.
          }),
    );
  }

  Future<void> _runNegotiation() async {
    final pc = _pc;
    if (pc == null || _closed) {
      return;
    }
    if (_answeringOffer) {
      _needsNegotiation = true;
      return;
    }
    if (pc.signalingState != RtcSignalingState.stable) {
      // Уже есть локальный offer (или применён remote offer): ждём answer
      // либо завершения ответа. Повторный запуск здесь дал бы busy-loop.
      return;
    }
    final restart = _iceRestartRequested;
    _iceRestartRequested = false;
    _makingOffer = true;
    try {
      _localSession = _nextSession();
      _negotiationSession = _localSession;
      final offer = await pc.createOffer(iceRestart: restart);
      if (_closed || _pc != pc) {
        return;
      }
      await pc.setLocalDescription(offer);
      final reset = _resetOfferPending;
      _resetOfferPending = false;
      await _publishSignal(
        PeerSignal.offer(session: _localSession, sdp: offer.sdp, reset: reset),
      );
    } catch (_) {
      if (!_closed) {
        _scheduleReconnect();
      }
    } finally {
      _makingOffer = false;
    }
  }

  int _nextSession() {
    _sessionCounter = (_sessionCounter + 1) & 0x7fffffff;
    if (_sessionCounter == 0) {
      _sessionCounter = 1;
    }
    return _sessionCounter;
  }

  void _scheduleReconnect({bool immediate = false}) {
    if (_closed) {
      return;
    }
    // Не запускаем новый reset-цикл, пока предыдущий ещё устанавливает
    // соединение. Иначе две стороны могут бесконечно пересоздавать PC,
    // реагируя на teardown друг друга. Таймаут соединения снимет флаг.
    if (_resetCycleActive && !immediate) {
      return;
    }
    _cancel(_connectTimer);
    _connectTimer = null;
    _cancel(_disconnectedTimer);
    _disconnectedTimer = null;
    _cancel(_iceRestartTimer);
    _iceRestartTimer = null;
    _cancel(_reconnectTimer);
    _reconnectTimer = null;
    _stopStats();

    if (_reconnectAttempt >= _config.maxReconnectAttempts) {
      _setState(PeerLinkState.failed);
      if (!_ready.isCompleted) {
        _ready.completeError(const PeerConnectTimeout());
      }
      unawaited(_disposeConnection());
      return;
    }

    _reconnectAttempt++;
    _setState(PeerLinkState.connecting);
    final delay = immediate ? Duration.zero : _backoff(_reconnectAttempt);
    _reconnectTimer = Timer(delay, () {
      unawaited(_reconnect());
    });
  }

  Duration _backoff(int attempt) {
    final exponential = _config.reconnectBaseDelay * pow(2, attempt - 1);
    final capped = exponential > _config.reconnectMaxDelay
        ? _config.reconnectMaxDelay
        : exponential;
    final jitter = 0.75 + _random.nextDouble() * 0.5;
    return Duration(
      milliseconds: (capped.inMilliseconds * jitter)
          .round()
          .clamp(1, _config.reconnectMaxDelay.inMilliseconds)
          .toInt(),
    );
  }

  Future<void> _reconnect() async {
    if (_closed) {
      return;
    }
    _resetCycleActive = true;
    await _disposeConnection();
    if (_closed) {
      return;
    }
    try {
      _initializing = true;
      try {
        await _openConnection(createChannels: true);
      } finally {
        _initializing = false;
      }
      _resetOfferPending = true;
      _armConnectTimeout();
      _scheduleNegotiation();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _armConnectTimeout() {
    _cancel(_connectTimer);
    _connectTimer = Timer(_config.connectTimeout, () {
      if (!_closed && _state != PeerLinkState.connected) {
        _resetCycleActive = false;
        _scheduleReconnect();
      }
    });
  }

  void _armIceRestartTimeout() {
    _cancel(_iceRestartTimer);
    _iceRestartTimer = Timer(_config.iceRestartTimeout, () {
      if (!_closed && _state != PeerLinkState.connected) {
        _scheduleReconnect(immediate: true);
      }
    });
  }

  void _startStats() {
    _stopStats();
    final interval = _config.statsInterval;
    if (interval <= Duration.zero) {
      return;
    }
    _lastStatsAt = DateTime.now();
    _lastStatsBytesSent = _stats.bytesSent;
    _statsTimer = Timer.periodic(interval, (_) {
      unawaited(_refreshStats());
    });
    unawaited(_refreshStats());
  }

  void _stopStats() {
    _cancel(_statsTimer);
    _statsTimer = null;
  }

  Future<void> _refreshStats() async {
    final pc = _pc;
    if (pc == null || _closed) {
      return;
    }
    try {
      final reports = await pc.getStats();
      _applyStats(reports);
    } catch (_) {
      // getStats может быть недоступен сразу после пересоздания.
    }
  }

  void _applyStats(List<RtcStats> reports) {
    RtcStats? bestPair;
    var bestScore = -1;
    var lost = 0;
    var received = 0;
    var hasLoss = false;

    for (final report in reports) {
      if (report.type == 'candidate-pair') {
        final state = report.values['state'];
        final succeeded = state == 'succeeded';
        final nominated =
            report.boolean('nominated') ||
            report.boolean('selected') ||
            report.values['selectedCandidatePair'] == true;
        final currentRtt = report.number('currentRoundTripTime') ?? 0;
        final totalRtt = report.number('totalRoundTripTime') ?? 0;
        final hasRtt = currentRtt > 0 || totalRtt > 0;
        final bytes =
            (report.number('bytesSent') ?? 0).toInt() +
            (report.number('bytesReceived') ?? 0).toInt();
        // Приоритет: nominated + есть RTT, затем nominated, затем RTT,
        // затем максимальный объём трафика. На Android первый попавшийся
        // candidate-pair может быть служебным с нулевым RTT.
        final score =
            (nominated && hasRtt ? 8 : 0) +
            (nominated ? 4 : 0) +
            (hasRtt ? 2 : 0) +
            (succeeded ? 1 : 0);
        if (succeeded && (score > bestScore ||
            (score == bestScore && bytes > 0))) {
          bestScore = score;
          bestPair = report;
        }
      }
      if (report.type == 'remote-inbound-rtp' || report.type == 'inbound-rtp') {
        final packetsLost = report.number('packetsLost');
        final packetsReceived = report.number('packetsReceived');
        if (packetsLost != null) {
          lost += packetsLost.toInt();
          received += (packetsReceived ?? 0).toInt();
          hasLoss = true;
        }
      }
    }

    final pair = bestPair;
    var bytesSent = pair?.number('bytesSent')?.toInt();
    var bytesReceived = pair?.number('bytesReceived')?.toInt();
    if (bytesSent == null || bytesReceived == null) {
      for (final report in reports) {
        if (report.type == 'transport') {
          bytesSent ??= report.number('bytesSent')?.toInt();
          bytesReceived ??= report.number('bytesReceived')?.toInt();
        }
      }
    }
    bytesSent ??= _sentBytes;
    bytesReceived ??= _receivedBytes;

    var rttSeconds =
        pair?.number('currentRoundTripTime') ?? pair?.number('roundTripTime');
    if (rttSeconds == null || rttSeconds == 0) {
      final total = pair?.number('totalRoundTripTime');
      final responses = pair?.number('responsesReceived');
      if (total != null && responses != null && responses > 0) {
        rttSeconds = total / responses;
      }
    }
    final rtt = rttSeconds == null || rttSeconds == 0
        ? _stats.rtt
        : _durationFromRtt(rttSeconds);

    final total = lost + received;
    final loss = hasLoss && total > 0
        ? (lost / total).clamp(0.0, 1.0).toDouble()
        : 0.0;

    final now = DateTime.now();
    var bitrate = _stats.outgoingBitrate;
    final lastAt = _lastStatsAt;
    if (lastAt != null) {
      final elapsed = now.difference(lastAt).inMicroseconds / 1000000;
      if (elapsed > 0 && bytesSent >= _lastStatsBytesSent) {
        bitrate = (((bytesSent - _lastStatsBytesSent) * 8) / elapsed).round();
      }
    }
    _lastStatsAt = now;
    _lastStatsBytesSent = bytesSent;

    _stats = PeerLinkStats(
      rtt: rtt,
      bytesSent: bytesSent,
      bytesReceived: bytesReceived,
      loss: loss,
      outgoingBitrate: bitrate < 0 ? 0 : bitrate,
    );
  }

  Duration _durationFromRtt(num value) {
    // WebRTC-стандарт: секунды. Linux и Android проверены в integration-тестах;
    // currentRoundTripTime может быть 0, тогда используется
    // totalRoundTripTime / responsesReceived.
    return Duration(microseconds: (value * 1000000).round());
  }

  Future<RtcDataChannel> _awaitOpenChannel(String label) {
    final channel = _channels[label];
    if (channel != null && channel.state == RtcDataChannelState.open) {
      return Future<RtcDataChannel>.value(channel);
    }
    final waiter = Completer<RtcDataChannel>();
    _openWaiters
        .putIfAbsent(label, () => <Completer<RtcDataChannel>>[])
        .add(waiter);
    return waiter.future.timeout(
      _config.connectTimeout,
      onTimeout: () {
        _openWaiters[label]?.remove(waiter);
        throw PeerChannelUnavailable(label);
      },
    );
  }

  Future<void> _waitForBuffer(RtcDataChannel channel) async {
    final low = _config.bufferedAmountLowThreshold;
    if (channel.bufferedAmount <= low) {
      return;
    }
    final completer = Completer<void>();
    late StreamSubscription<void> subscription;
    Timer? poll;
    var finished = false;

    void finish() {
      if (finished) {
        return;
      }
      finished = true;
      unawaited(subscription.cancel());
      poll?.cancel();
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    subscription = channel.bufferedAmountLow.listen((_) {
      if (channel.bufferedAmount <= low ||
          channel.state != RtcDataChannelState.open) {
        finish();
      }
    });
    poll = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (channel.bufferedAmount <= low ||
          channel.state != RtcDataChannelState.open) {
        finish();
      }
    });
    if (channel.bufferedAmount <= low) {
      finish();
    }
    await completer.future;
  }

  Future<void> _closeFromRemote() async {
    if (_closed) {
      return;
    }
    _remoteClosed = true;
    await _shutdown(remote: true);
  }

  Future<void> _shutdown({required bool remote}) async {
    if (_closed && !remote) {
      return;
    }
    _closed = true;
    _cancelAllTimers();
    await _disposeConnection();
    _setState(PeerLinkState.closed);
    if (!_ready.isCompleted) {
      _ready.completeError(const PeerClosed());
    }
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
    if (!_stateChanges.isClosed) {
      await _stateChanges.close();
    }
  }

  Future<void> _disposeConnection() async {
    final pc = _pc;
    _pc = null;
    _stopStats();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    for (final channel in List<RtcDataChannel>.of(_channels.values)) {
      _failOpenWaiters(channel.label);
      try {
        await channel.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        // Закрытие канала не должно блокировать dispose.
      }
    }
    _channels.clear();
    _openWaiters.clear();
    _pendingRemoteCandidates.clear();
    _remoteDescriptionSet = false;
    _makingOffer = false;
    _answeringOffer = false;
    _needsNegotiation = false;
    _resetCycleActive = false;
    _negotiationInFlight = null;
    if (pc != null) {
      try {
        await pc.close().timeout(const Duration(seconds: 3));
      } catch (_) {
        // Платформа могла уже закрыть соединение или не отвечать.
      }
    }
  }

  void _cancelAllTimers() {
    _cancel(_connectTimer);
    _connectTimer = null;
    _cancel(_disconnectedTimer);
    _disconnectedTimer = null;
    _cancel(_iceRestartTimer);
    _iceRestartTimer = null;
    _cancel(_reconnectTimer);
    _reconnectTimer = null;
    _stopStats();
  }

  void _cancel(Timer? timer) {
    timer?.cancel();
  }

  void _setState(PeerLinkState next) {
    if (_state == next) {
      return;
    }
    _state = next;
    if (!_stateChanges.isClosed) {
      _stateChanges.add(next);
    }
  }

  /// Сравнение PeerId для ролей perfect negotiation.
  ///
  /// Меньший ключ — polite, больший — impolite. Это детерминированно и
  /// симметрично на обеих сторонах.
  static int comparePeerIds(PeerId a, PeerId b) {
    final left = a.publicKey;
    final right = b.publicKey;
    final length = left.length < right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final diff = left[i] - right[i];
      if (diff != 0) {
        return diff;
      }
    }
    return left.length - right.length;
  }
}

class _ChannelQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() action) {
    final completer = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        await action();
        if (!completer.isCompleted) {
          completer.complete();
        }
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return completer.future;
  }
}
