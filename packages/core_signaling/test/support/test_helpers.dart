import 'dart:async';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_signaling/core_signaling.dart';

class TestPeer {
  TestPeer._(this.identity, this.signer);

  final CryptoIdentity identity;
  final CryptoSigner signer;

  PeerId get peerId => identity.peerId;

  static Future<TestPeer> create() async {
    final identity = await generateIdentity();
    return TestPeer._(identity, CryptoSigner(identity.ed25519PrivateKey));
  }

  SignalingSecurityConfig security(
    GroupSecret groupSecret, {
    Set<PeerId>? allowedPeers,
  }) => SignalingSecurityConfig(
    peerId: peerId,
    signer: signer,
    groupSecret: groupSecret,
    allowedPeers: allowedPeers,
  );

  NodeCapabilities capabilities({
    SignalingPlatform platform = SignalingPlatform.linux,
    bool canRelay = true,
  }) => NodeCapabilities(
    platform: platform,
    publicIpv6: '2001:db8::1',
    uptime: const Duration(minutes: 5),
    canRelay: canRelay,
    canSfu: false,
    neighbors: <PeerId>[peerId],
  );
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 20),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(reason ?? 'Condition was not met', timeout);
    }
    await Future<void>.delayed(interval);
  }
}

Future<List<T>> collectFor<T>(Stream<T> stream, Duration duration) async {
  final result = <T>[];
  final subscription = stream.listen(result.add);
  await Future<void>.delayed(duration);
  await subscription.cancel();
  return result;
}
