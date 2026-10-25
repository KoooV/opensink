import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'package:test/test.dart';

void main() {
  test(
    'identity-bound bundle детерминирован и привязан к Ed25519 identity',
    () async {
      final seed = Uint8List.fromList(
        List<int>.generate(32, (index) => (index * 7 + 3) & 0xff),
      );
      final identitySeed = crypto_pkg.SecretKey(seed);
      final x3dh = X3DH();

      final first = await x3dh.generateIdentityBoundKeyBundle(
        identitySeed: identitySeed,
      );
      final second = await x3dh.generateIdentityBoundKeyBundle(
        identitySeed: identitySeed,
      );

      final identityPair = await crypto_pkg.Ed25519().newKeyPairFromSeed(seed);
      final identityPublic = await identityPair.extractPublicKey();
      expect(
        (first.ed25519PublicKey as crypto_pkg.SimplePublicKey).bytes,
        orderedEquals(identityPublic.bytes),
      );

      const codec = X3dhBundleCodec();
      expect(
        codec.encode(first.toPublicBundle()),
        orderedEquals(codec.encode(second.toPublicBundle())),
      );

      final receiver = await x3dh.generateKeyBundle();
      final handshake = await E2eSessionManager(localBundle: receiver).initiate(
        peerId: 'identity-bound',
        remoteBundle: first.toPublicBundle(),
        expectedEd25519PublicKey: first.ed25519PublicKey,
      );
      expect(handshake.isOk, isTrue);
    },
  );
}
