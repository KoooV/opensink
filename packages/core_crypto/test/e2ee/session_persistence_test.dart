import 'dart:convert';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:test/test.dart';

class _FailingStore implements E2eSessionStore {
  final MemoryE2eSessionStore _inner = MemoryE2eSessionStore();
  bool failSaves = false;

  @override
  Future<Result<Uint8List?, E2eSessionStoreError>> load(String peerId) =>
      _inner.load(peerId);

  @override
  Future<Result<void, E2eSessionStoreError>> save(
    String peerId,
    Uint8List state,
  ) async {
    if (failSaves) return const Err(E2eSessionStoreUnavailable());
    return _inner.save(peerId, state);
  }

  @override
  Future<Result<void, E2eSessionStoreError>> delete(String peerId) =>
      _inner.delete(peerId);
}

Future<void> _establish(E2eSessionManager alice, E2eSessionManager bob) async {
  final handshake = await alice.initiate(
    peerId: 'bob',
    remoteBundle: bob.publicBundle,
    expectedEd25519PublicKey: bob.publicBundle.ed25519PublicKey,
  );
  expect(handshake.isOk, isTrue);
  final accepted = await bob.accept(
    peerId: 'alice',
    handshake: handshake.unwrap().toBytes(),
  );
  expect(accepted.isOk, isTrue);
}

Future<void> _exchange(
  E2eSessionManager from,
  E2eSessionManager to, {
  required String fromPeer,
  required String toPeer,
  required String text,
}) async {
  final encrypted = await from.encrypt(
    peerId: toPeer,
    plaintext: Uint8List.fromList(utf8.encode(text)),
  );
  expect(encrypted.isOk, isTrue);
  final decrypted = await to.decrypt(
    peerId: fromPeer,
    wireFormat: encrypted.unwrap(),
  );
  expect(decrypted.isOk, isTrue);
  expect(utf8.decode(decrypted.unwrap()), text);
}

void main() {
  group('E2eSessionManager persistence', () {
    test(
      'restores ratchet after restart and continues both directions',
      () async {
        final x3dh = X3DH();
        final aliceBundle = await x3dh.generateKeyBundle();
        final bobBundle = await x3dh.generateKeyBundle();
        final aliceStore = MemoryE2eSessionStore();
        final bobStore = MemoryE2eSessionStore();

        final alice = E2eSessionManager(
          localBundle: aliceBundle,
          store: aliceStore,
        );
        final bob = E2eSessionManager(localBundle: bobBundle, store: bobStore);
        await _establish(alice, bob);
        await _exchange(
          alice,
          bob,
          fromPeer: 'alice',
          toPeer: 'bob',
          text: 'one',
        );
        await _exchange(
          bob,
          alice,
          fromPeer: 'bob',
          toPeer: 'alice',
          text: 'two',
        );

        expect(aliceStore.length, 1);
        expect(bobStore.length, 1);

        final aliceRestarted = E2eSessionManager(
          localBundle: aliceBundle,
          store: aliceStore,
        );
        final bobRestarted = E2eSessionManager(
          localBundle: bobBundle,
          store: bobStore,
        );
        expect(aliceRestarted.hasSession('bob'), isFalse);
        expect(bobRestarted.hasSession('alice'), isFalse);

        expect((await aliceRestarted.restoreSession('bob')).isOk, isTrue);
        expect((await bobRestarted.restoreSession('alice')).isOk, isTrue);
        expect(aliceRestarted.hasSession('bob'), isTrue);
        expect(bobRestarted.hasSession('alice'), isTrue);

        await _exchange(
          aliceRestarted,
          bobRestarted,
          fromPeer: 'alice',
          toPeer: 'bob',
          text: 'after restart',
        );
        await _exchange(
          bobRestarted,
          aliceRestarted,
          fromPeer: 'bob',
          toPeer: 'alice',
          text: 'reply after restart',
        );
      },
    );

    test(
      'encrypt/decrypt load session lazily without explicit restore',
      () async {
        final x3dh = X3DH();
        final aliceBundle = await x3dh.generateKeyBundle();
        final bobBundle = await x3dh.generateKeyBundle();
        final aliceStore = MemoryE2eSessionStore();
        final bobStore = MemoryE2eSessionStore();

        final alice = E2eSessionManager(
          localBundle: aliceBundle,
          store: aliceStore,
        );
        final bob = E2eSessionManager(localBundle: bobBundle, store: bobStore);
        await _establish(alice, bob);

        final bobRestarted = E2eSessionManager(
          localBundle: bobBundle,
          store: bobStore,
        );
        expect(bobRestarted.hasSession('alice'), isFalse);
        await _exchange(
          alice,
          bobRestarted,
          fromPeer: 'alice',
          toPeer: 'bob',
          text: 'lazy restore',
        );
        expect(bobRestarted.hasSession('alice'), isTrue);
      },
    );

    test('persistence failure is fail-closed', () async {
      final x3dh = X3DH();
      final aliceBundle = await x3dh.generateKeyBundle();
      final bobBundle = await x3dh.generateKeyBundle();
      final store = _FailingStore()..failSaves = true;

      final alice = E2eSessionManager(localBundle: aliceBundle, store: store);
      final bob = E2eSessionManager(localBundle: bobBundle);

      final handshake = await alice.initiate(
        peerId: 'bob',
        remoteBundle: bob.publicBundle,
        expectedEd25519PublicKey: bob.publicBundle.ed25519PublicKey,
      );
      expect(handshake.isErr, isTrue);
      expect(handshake.unwrapErr(), isA<SessionPersistenceFailed>());
      expect(alice.hasSession('bob'), isFalse);

      store.failSaves = false;
      await _establish(alice, bob);
      store.failSaves = true;
      final encrypted = await alice.encrypt(
        peerId: 'bob',
        plaintext: Uint8List.fromList(utf8.encode('must not leak')),
      );
      expect(encrypted.isErr, isTrue);
      expect(encrypted.unwrapErr(), isA<SessionPersistenceFailed>());
    });

    test('corrupted state is deleted and allows a new handshake', () async {
      final x3dh = X3DH();
      final aliceBundle = await x3dh.generateKeyBundle();
      final bobBundle = await x3dh.generateKeyBundle();
      final store = MemoryE2eSessionStore();
      await store.save('bob', Uint8List.fromList(<int>[1, 2, 3, 4]));

      final alice = E2eSessionManager(localBundle: aliceBundle, store: store);
      final restored = await alice.restoreSession('bob');
      expect(restored.isOk, isTrue);
      expect(alice.hasSession('bob'), isFalse);
      expect(store.length, 0);

      final bob = E2eSessionManager(localBundle: bobBundle);
      await _establish(alice, bob);
      await _exchange(
        alice,
        bob,
        fromPeer: 'alice',
        toPeer: 'bob',
        text: 'recovered',
      );
    });
  });
}
