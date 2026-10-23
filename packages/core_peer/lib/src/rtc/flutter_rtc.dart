import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'rtc_types.dart';

/// Реализация RTC-абстракций поверх flutter_webrtc.
///
/// Всё платформенное различие web/native скрыто за этим файлом:
/// - на web используется dart_webrtc/browser API, на desktop — нативный плагин;
/// - `bufferedAmount` читается синхронно (getter), а не через
///   `getBufferedAmount()` (в 0.10.8 он может быть UnimplementedError);
/// - `close()` на native дополняется `dispose()`, на web достаточно close;
/// - имена enum-ов и nullable-поля SDP/кандидатов нормализуются здесь.
class FlutterRtcPeerFactory implements RtcPeerFactory {
  const FlutterRtcPeerFactory();

  @override
  Future<RtcPeerConnection> create(Map<String, dynamic> configuration) async {
    final connection = await rtc.createPeerConnection(configuration);
    return FlutterRtcPeerConnection(connection);
  }
}

class FlutterRtcPeerConnection implements RtcPeerConnection {
  FlutterRtcPeerConnection(this._pc)
    : _signalingState = _mapSignalingState(_pc.signalingState) {
    _pc.onSignalingState = (state) {
      _signalingState = _mapSignalingState(state);
    };
    _pc.onIceCandidate = (candidate) {
      final value = candidate.candidate;
      if (value == null || value.isEmpty) {
        return;
      }
      _iceCandidates.add(
        RtcIceCandidateData(
          candidate: value,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };
    _pc.onConnectionState = (state) {
      _connectionStates.add(_mapConnectionState(state));
    };
    _pc.onDataChannel = (channel) {
      _dataChannels.add(FlutterRtcDataChannel(channel));
    };
    _pc.onRenegotiationNeeded = () {
      _negotiationNeeded.add(null);
    };
  }

  final rtc.RTCPeerConnection _pc;
  RtcSignalingState _signalingState;
  final StreamController<RtcIceCandidateData> _iceCandidates =
      StreamController<RtcIceCandidateData>.broadcast();
  final StreamController<RtcConnectionState> _connectionStates =
      StreamController<RtcConnectionState>.broadcast();
  final StreamController<RtcDataChannel> _dataChannels =
      StreamController<RtcDataChannel>.broadcast();
  final StreamController<void> _negotiationNeeded =
      StreamController<void>.broadcast();
  bool _closed = false;

  @override
  RtcSignalingState get signalingState => _signalingState;

  @override
  RtcConnectionState get connectionState =>
      _mapConnectionState(_pc.connectionState);

  @override
  Stream<RtcIceCandidateData> get iceCandidates => _iceCandidates.stream;

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
    final constraints = <String, dynamic>{if (iceRestart) 'iceRestart': true};
    final offer = await _pc.createOffer(constraints);
    return RtcSessionDescriptionData(
      type: offer.type ?? 'offer',
      sdp: offer.sdp ?? '',
    );
  }

  @override
  Future<RtcSessionDescriptionData> createAnswer() async {
    final answer = await _pc.createAnswer();
    return RtcSessionDescriptionData(
      type: answer.type ?? 'answer',
      sdp: answer.sdp ?? '',
    );
  }

  @override
  Future<void> setLocalDescription(RtcSessionDescriptionData description) =>
      _pc.setLocalDescription(
        rtc.RTCSessionDescription(description.sdp, description.type),
      );

  @override
  Future<void> setRemoteDescription(RtcSessionDescriptionData description) =>
      _pc.setRemoteDescription(
        rtc.RTCSessionDescription(description.sdp, description.type),
      );

  @override
  Future<void> addIceCandidate(RtcIceCandidateData candidate) =>
      _pc.addCandidate(
        rtc.RTCIceCandidate(
          candidate.candidate,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        ),
      );

  @override
  Future<void> restartIce() => _pc.restartIce();

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _pc.close();
    } catch (_) {
      // Соединение могло быть уже закрыто платформой.
    }
    try {
      await _pc.dispose();
    } catch (_) {
      // На web dispose не реализован; close достаточно.
    }
    await _iceCandidates.close();
    await _connectionStates.close();
    await _dataChannels.close();
    await _negotiationNeeded.close();
  }

  @override
  Future<List<RtcStats>> getStats() async {
    final reports = await _pc.getStats();
    return reports
        .map(
          (report) => RtcStats(
            id: report.id,
            type: report.type,
            values: Map<String, Object?>.from(report.values),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<RtcDataChannel> createDataChannel(
    String label, {
    required bool ordered,
    int? maxRetransmits,
  }) async {
    final init = rtc.RTCDataChannelInit()..ordered = ordered;
    if (maxRetransmits != null) {
      init.maxRetransmits = maxRetransmits;
    }
    final channel = await _pc.createDataChannel(label, init);
    return FlutterRtcDataChannel(channel);
  }
}

class FlutterRtcDataChannel implements RtcDataChannel {
  FlutterRtcDataChannel(this._channel) {
    _state = _mapDataChannelState(_channel.state);
    _channel.onDataChannelState = (state) {
      _state = _mapDataChannelState(state);
      if (!_states.isClosed) {
        _states.add(_state);
      }
    };
    _channel.onMessage = (message) {
      if (!message.isBinary || _messages.isClosed) {
        return;
      }
      _messages.add(Uint8List.fromList(message.binary));
    };
    _channel.onBufferedAmountLow = (_) {
      if (!_bufferedAmountLow.isClosed) {
        _bufferedAmountLow.add(null);
      }
    };
  }

  final rtc.RTCDataChannel _channel;
  final StreamController<RtcDataChannelState> _states =
      StreamController<RtcDataChannelState>.broadcast();
  final StreamController<List<int>> _messages =
      StreamController<List<int>>.broadcast();
  final StreamController<void> _bufferedAmountLow =
      StreamController<void>.broadcast();
  RtcDataChannelState _state = RtcDataChannelState.connecting;

  @override
  String get label => _channel.label ?? '';

  @override
  RtcDataChannelState get state => _state;

  @override
  int get bufferedAmount => _channel.bufferedAmount ?? 0;

  @override
  Stream<RtcDataChannelState> get states => _states.stream;

  @override
  Stream<List<int>> get messages => _messages.stream;

  @override
  Stream<void> get bufferedAmountLow => _bufferedAmountLow.stream;

  @override
  Future<void> setBufferedAmountLowThreshold(int bytes) async {
    _channel.bufferedAmountLowThreshold = bytes;
  }

  @override
  Future<void> send(List<int> bytes) =>
      _channel.send(rtc.RTCDataChannelMessage.fromBinary(asUint8List(bytes)));

  @override
  Future<void> close() async {
    try {
      await _channel.close();
    } catch (_) {
      // Канал мог быть закрыт вместе с peer connection.
    }
  }
}

RtcSignalingState _mapSignalingState(rtc.RTCSignalingState? state) =>
    switch (state) {
      rtc.RTCSignalingState.RTCSignalingStateStable => RtcSignalingState.stable,
      rtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer =>
        RtcSignalingState.haveLocalOffer,
      rtc.RTCSignalingState.RTCSignalingStateHaveRemoteOffer =>
        RtcSignalingState.haveRemoteOffer,
      rtc.RTCSignalingState.RTCSignalingStateHaveLocalPrAnswer =>
        RtcSignalingState.haveLocalPrAnswer,
      rtc.RTCSignalingState.RTCSignalingStateHaveRemotePrAnswer =>
        RtcSignalingState.haveRemotePrAnswer,
      rtc.RTCSignalingState.RTCSignalingStateClosed =>
        RtcSignalingState.closed,
      // На native getter возвращает null до первого события signalingState.
      // null означает «ещё stable/new», а не «closed».
      _ => RtcSignalingState.stable,
    };

RtcConnectionState _mapConnectionState(rtc.RTCPeerConnectionState? state) =>
    switch (state) {
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew =>
        RtcConnectionState.newState,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
        RtcConnectionState.connecting,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
        RtcConnectionState.connected,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
        RtcConnectionState.disconnected,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
        RtcConnectionState.failed,
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
        RtcConnectionState.closed,
      _ => RtcConnectionState.newState,
    };

RtcDataChannelState _mapDataChannelState(rtc.RTCDataChannelState? state) =>
    switch (state) {
      rtc.RTCDataChannelState.RTCDataChannelConnecting =>
        RtcDataChannelState.connecting,
      rtc.RTCDataChannelState.RTCDataChannelOpen => RtcDataChannelState.open,
      rtc.RTCDataChannelState.RTCDataChannelClosing =>
        RtcDataChannelState.closing,
      rtc.RTCDataChannelState.RTCDataChannelClosed =>
        RtcDataChannelState.closed,
      _ => RtcDataChannelState.connecting,
    };
