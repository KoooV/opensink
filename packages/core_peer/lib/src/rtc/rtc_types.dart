import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Сигнальное состояние RTCPeerConnection (подмножество, нужное
/// perfect negotiation).
enum RtcSignalingState {
  stable,
  haveLocalOffer,
  haveRemoteOffer,
  haveLocalPrAnswer,
  haveRemotePrAnswer,
  closed,
}

enum RtcConnectionState {
  newState,
  connecting,
  connected,
  disconnected,
  failed,
  closed,
}

enum RtcDataChannelState { connecting, open, closing, closed }

@immutable
class RtcSessionDescriptionData {
  const RtcSessionDescriptionData({required this.type, required this.sdp});

  const RtcSessionDescriptionData.rollback() : type = 'rollback', sdp = '';

  final String type;
  final String sdp;

  Map<String, dynamic> toMap() => <String, dynamic>{'type': type, 'sdp': sdp};

  @override
  String toString() => 'RtcSessionDescriptionData($type)';
}

@immutable
class RtcIceCandidateData {
  const RtcIceCandidateData({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
}

/// Снимок одной записи getStats.
@immutable
class RtcStats {
  const RtcStats({required this.id, required this.type, required this.values});

  final String id;
  final String type;
  final Map<String, Object?> values;

  num? number(String key) {
    final value = values[key];
    return value is num ? value : null;
  }

  bool boolean(String key) => values[key] == true;
}

/// Канал данных с потоками, не зависящими от платформы.
abstract interface class RtcDataChannel {
  String get label;
  RtcDataChannelState get state;
  int get bufferedAmount;
  Stream<RtcDataChannelState> get states;
  Stream<List<int>> get messages;

  /// Срабатывает, когда bufferedAmount опускается ниже порога.
  Stream<void> get bufferedAmountLow;

  Future<void> setBufferedAmountLowThreshold(int bytes);

  Future<void> send(List<int> bytes);

  Future<void> close();
}

/// Кросс-платформенная обёртка над RTCPeerConnection.
///
/// Единственное место, где допустимы различия web/native, — реализация
/// [RtcPeerFactory]. Остальной peer-слой работает только с этим интерфейсом.
abstract interface class RtcPeerConnection {
  RtcSignalingState get signalingState;
  RtcConnectionState get connectionState;
  Stream<RtcIceCandidateData> get iceCandidates;
  Stream<RtcConnectionState> get connectionStates;
  Stream<RtcDataChannel> get dataChannels;
  Stream<void> get negotiationNeeded;

  Future<RtcSessionDescriptionData> createOffer({bool iceRestart = false});

  Future<RtcSessionDescriptionData> createAnswer();

  Future<void> setLocalDescription(RtcSessionDescriptionData description);

  Future<void> setRemoteDescription(RtcSessionDescriptionData description);

  Future<void> addIceCandidate(RtcIceCandidateData candidate);

  Future<void> restartIce();

  Future<void> close();

  Future<List<RtcStats>> getStats();

  Future<RtcDataChannel> createDataChannel(
    String label, {
    required bool ordered,
    int? maxRetransmits,
  });
}

abstract interface class RtcPeerFactory {
  Future<RtcPeerConnection> create(Map<String, dynamic> configuration);
}

/// Утилита для тестов и реализаций: бинарное сообщение без копирования.
Uint8List asUint8List(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
