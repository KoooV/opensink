import 'dart:convert';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'package:test/test.dart';

void main() {
  group('E2eSessionManager / X3DH + DoubleRatchet', () {
    test(
      'establish session from bundle and exchange messages both ways',
      () async {
        final x3dh = X3DH();
        final alice = E2eSessionManager(
          localBundle: await x3dh.generateKeyBundle(),
        );
        final bob = E2eSessionManager(
          localBundle: await x3dh.generateKeyBundle(),
        );

        const bundleCodec = X3dhBundleCodec();
        final bobBundle = bundleCodec.decode(
          bundleCodec.encode(bob.publicBundle),
        );
        expect(bobBundle, isNotNull);

        final handshake = await alice.initiate(
          peerId: 'bob',
          remoteBundle: bobBundle!,
          expectedEd25519PublicKey: bob.publicBundle.ed25519PublicKey,
        );
        expect(handshake.isOk, isTrue);

        final accepted = await bob.accept(
          peerId: 'alice',
          handshake: handshake.unwrap().toBytes(),
        );
        expect(accepted.isOk, isTrue);

        final plaintext = Uint8List.fromList(utf8.encode('hello bob'));
        final encrypted = await alice.encrypt(
          peerId: 'bob',
          plaintext: plaintext,
        );
        expect(encrypted.isOk, isTrue);

        final decrypted = await bob.decrypt(
          peerId: 'alice',
          wireFormat: encrypted.unwrap(),
        );
        expect(decrypted.isOk, isTrue);
        expect(decrypted.unwrap(), orderedEquals(plaintext));

        final reply = Uint8List.fromList(utf8.encode('hello alice'));
        final encryptedReply = await bob.encrypt(
          peerId: 'alice',
          plaintext: reply,
        );
        expect(encryptedReply.isOk, isTrue);
        final decryptedReply = await alice.decrypt(
          peerId: 'bob',
          wireFormat: encryptedReply.unwrap(),
        );
        expect(decryptedReply.isOk, isTrue);
        expect(decryptedReply.unwrap(), orderedEquals(reply));
      },
    );

    test(
      'rejects bundle whose Ed25519 key differs from expected peer',
      () async {
        final x3dh = X3DH();
        final alice = E2eSessionManager(
          localBundle: await x3dh.generateKeyBundle(),
        );
        final bob = E2eSessionManager(
          localBundle: await x3dh.generateKeyBundle(),
        );
        final otherSigning = await crypto_pkg.Ed25519().newKeyPair();
        final otherEd = await otherSigning.extractPublicKey();

        final result = await alice.initiate(
          peerId: 'bob',
          remoteBundle: bob.publicBundle,
          expectedEd25519PublicKey: otherEd,
        );
        expect(result.isErr, isTrue);
        expect(result.unwrapErr(), isA<InvalidSignature>());
        expect(alice.hasSession('bob'), isFalse);
      },
    );

    test('rejects tampered SPK binding before DH', () async {
      final x3dh = X3DH();
      final alice = E2eSessionManager(
        localBundle: await x3dh.generateKeyBundle(),
      );
      final bob = E2eSessionManager(
        localBundle: await x3dh.generateKeyBundle(),
      );
      final signature = bob.publicBundle.signedPrekeySignature;
      final tampered = X3DHPublicBundle(
        identityKey: bob.publicBundle.identityKey,
        signedPrekey: bob.publicBundle.signedPrekey,
        ed25519PublicKey: bob.publicBundle.ed25519PublicKey,
        signedPrekeySignature: signature == null
            ? null
            : '00${signature.substring(2)}',
      );

      final result = await alice.initiate(
        peerId: 'bob',
        remoteBundle: tampered,
        expectedEd25519PublicKey: tampered.ed25519PublicKey,
      );
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidSignature>());
      expect(alice.hasSession('bob'), isFalse);
    });

    test(
      'missing session, tampered ciphertext and replay fail closed',
      () async {
        final x3dh = X3DH();
        final alice = E2eSessionManager(
          localBundle: await x3dh.generateKeyBundle(),
        );
        final bob = E2eSessionManager(
          localBundle: await x3dh.generateKeyBundle(),
        );

        final noSession = await alice.encrypt(
          peerId: 'bob',
          plaintext: Uint8List.fromList(<int>[1, 2, 3]),
        );
        expect(noSession.isErr, isTrue);
        expect(noSession.unwrapErr(), isA<SessionUnavailable>());

        final handshake = await alice.initiate(
          peerId: 'bob',
          remoteBundle: bob.publicBundle,
          expectedEd25519PublicKey: bob.publicBundle.ed25519PublicKey,
        );
        await bob.accept(
          peerId: 'alice',
          handshake: handshake.unwrap().toBytes(),
        );

        final encrypted = await alice.encrypt(
          peerId: 'bob',
          plaintext: Uint8List.fromList(utf8.encode('secret')),
        );
        final wire = encrypted.unwrap();
        final tampered = Uint8List.fromList(wire);
        tampered[tampered.length - 1] ^= 0xFF;

        final rejected = await bob.decrypt(
          peerId: 'alice',
          wireFormat: tampered,
        );
        expect(rejected.isErr, isTrue);
        expect(rejected.unwrapErr(), isA<DecryptionFailed>());

        final accepted = await bob.decrypt(peerId: 'alice', wireFormat: wire);
        expect(accepted.isOk, isTrue);
        final replay = await bob.decrypt(peerId: 'alice', wireFormat: wire);
        expect(replay.isErr, isTrue);
        expect(replay.unwrapErr(), isA<DecryptionFailed>());
      },
    );
  });
}
