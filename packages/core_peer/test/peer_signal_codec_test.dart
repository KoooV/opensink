import 'package:core_peer/core_peer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PeerSignalCodec', () {
    test('roundtrip offer/answer/ice/hangup', () {
      final signals = <PeerSignal>[
        const PeerSignal.offer(session: 7, sdp: 'v=0\r\n', reset: true),
        const PeerSignal.answer(session: 7, sdp: 'v=0\r\n'),
        const PeerSignal.ice(
          session: 7,
          candidate: 'candidate:1 1 udp 1 2001:db8::1 5000 typ host',
          sdpMid: '0',
          sdpMLineIndex: 0,
        ),
        const PeerSignal.hangup(session: 7),
      ];
      for (final signal in signals) {
        final decoded = PeerSignalCodec.decode(PeerSignalCodec.encode(signal));
        expect(decoded, isNotNull);
        expect(decoded!.kind, signal.kind);
        expect(decoded.session, signal.session);
        expect(decoded.sdp, signal.sdp);
        expect(decoded.candidate, signal.candidate);
        expect(decoded.sdpMid, signal.sdpMid);
        expect(decoded.sdpMLineIndex, signal.sdpMLineIndex);
        expect(decoded.reset, signal.reset);
      }
    });

    test('rejects malformed and truncated payload', () {
      expect(PeerSignalCodec.decode(const <int>[]), isNull);
      expect(PeerSignalCodec.decode(const <int>[1, 2, 3]), isNull);
      expect(
        PeerSignalCodec.decode(
          List<int>.filled(PeerSignalCodec.maxSignalBytes + 1, 65),
        ),
        isNull,
      );
    });

    test('rejects wrong version and unknown kind', () {
      expect(
        PeerSignalCodec.decode('{"v":2,"k":"offer","s":1,"d":"x"}'.codeUnits),
        isNull,
      );
      expect(
        PeerSignalCodec.decode('{"v":1,"k":"bogus","s":1}'.codeUnits),
        isNull,
      );
    });
  });
}
