import 'package:core_peer/core_peer.dart';
import 'package:core_peer/core_peer_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Smoke-тест публичных STUN из defaultPublicStun.
///
/// Проверяет, что ICE gathering получает reflexive-кандидат (typ srflx)
/// через хотя бы один публичный STUN. В сетях, где UDP/STUN заблокирован,
/// тест нужно запускать с явным конфигом STUN.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('default public STUN produces a reflexive ICE candidate', () async {
    const factory = FlutterRtcPeerFactory();
    const config = PeerConnectionConfig();
    final pc = await factory.create(config.toRtcConfiguration());
    addTearDown(pc.close);

    final candidates = <String>[];
    final subscription = pc.iceCandidates.listen((candidate) {
      candidates.add(candidate.candidate);
    });
    addTearDown(subscription.cancel);

    await pc.createDataChannel('probe', ordered: true);
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (candidates.any((candidate) => candidate.contains(' typ srflx '))) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    expect(
      candidates.any((candidate) => candidate.contains(' typ srflx ')),
      isTrue,
      reason:
          'no srflx candidate after 20s; candidates=${candidates.length}. '
          'Проверить доступность defaultPublicStun в сети.',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));
}
