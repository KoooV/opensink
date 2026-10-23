import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

enum PeerSignalKind { offer, answer, ice, hangup }

/// Сигнальное сообщение peer-слоя.
///
/// [session] — идентификатор локальной навигации (offer/answer). Он нужен,
/// чтобы отбрасывать кандидатов и ответы от предыдущего PeerConnection после
/// пересоздания. Значение генерирует сторона, отправившая offer; answer его
/// повторяет.
@immutable
class PeerSignal {
  const PeerSignal({
    required this.kind,
    required this.session,
    this.sdp,
    this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
    this.reset = false,
  });

  const PeerSignal.offer({
    required int session,
    required String sdp,
    bool reset = false,
  }) : this(
         kind: PeerSignalKind.offer,
         session: session,
         sdp: sdp,
         reset: reset,
       );

  const PeerSignal.answer({required int session, required String sdp})
    : this(kind: PeerSignalKind.answer, session: session, sdp: sdp);

  const PeerSignal.ice({
    required int session,
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) : this(
         kind: PeerSignalKind.ice,
         session: session,
         candidate: candidate,
         sdpMid: sdpMid,
         sdpMLineIndex: sdpMLineIndex,
       );

  const PeerSignal.hangup({required int session})
    : this(kind: PeerSignalKind.hangup, session: session);

  final PeerSignalKind kind;
  final int session;
  final String? sdp;
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  /// Признак полного пересоздания PeerConnection (reconnect, не ICE restart).
  final bool reset;

  @override
  String toString() => 'PeerSignal($kind, session=$session)';
}

/// Кодировщик сигнальных сообщений внутри payload слоя 5.
///
/// Формат — компактный JSON UTF-8. Подпись/шифрование и авторизация уже
/// выполнены `core_signaling`; здесь только транспортный уровень.
// ignore: avoid_classes_with_only_static_members
abstract final class PeerSignalCodec {
  static const version = 1;
  static const maxSignalBytes = 128 * 1024;

  static Uint8List encode(PeerSignal signal) {
    final map = <String, Object?>{
      'v': version,
      'k': signal.kind.name,
      's': signal.session,
      if (signal.sdp != null) 'd': signal.sdp,
      if (signal.candidate != null) 'c': signal.candidate,
      if (signal.sdpMid != null) 'm': signal.sdpMid,
      if (signal.sdpMLineIndex != null) 'i': signal.sdpMLineIndex,
      if (signal.reset) 'r': true,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  static PeerSignal? decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxSignalBytes) {
      return null;
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> || decoded['v'] != version) {
        return null;
      }
      final kindName = decoded['k'];
      final session = decoded['s'];
      if (kindName is! String || session is! int) {
        return null;
      }
      PeerSignalKind? kind;
      for (final value in PeerSignalKind.values) {
        if (value.name == kindName) {
          kind = value;
          break;
        }
      }
      if (kind == null) {
        return null;
      }
      final sdp = decoded['d'];
      final candidate = decoded['c'];
      final sdpMid = decoded['m'];
      final mLine = decoded['i'];
      final reset = decoded['r'];
      if (reset != null && reset is! bool) {
        return null;
      }
      if (sdp != null && sdp is! String) {
        return null;
      }
      if (candidate != null && candidate is! String) {
        return null;
      }
      if (sdpMid != null && sdpMid is! String) {
        return null;
      }
      if (mLine != null && mLine is! int) {
        return null;
      }
      if ((kind == PeerSignalKind.offer || kind == PeerSignalKind.answer) &&
          (sdp == null || sdp.isEmpty)) {
        return null;
      }
      if (kind == PeerSignalKind.ice &&
          (candidate == null || candidate.isEmpty)) {
        return null;
      }
      return PeerSignal(
        kind: kind,
        session: session,
        sdp: sdp as String?,
        candidate: candidate as String?,
        sdpMid: sdpMid as String?,
        sdpMLineIndex: mLine as int?,
        reset: reset == true,
      );
    } catch (_) {
      return null;
    }
  }
}
