import 'dart:typed_data';

import 'package:app/e2e/secure_e2e_session_store.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:test/test.dart';

void main() {
  group('SecureE2eSessionStore', () {
    test('seals state and restores it across store instances', () async {
      final keyStore = MemorySecureKeyStore();
      final store = SecureE2eSessionStore(keyStore, scope: 'user-a');
      final state = Uint8List.fromList(
        List<int>.generate(96, (index) => index & 0xFF),
      );

      final saved = await store.save('peer-1', state);
      expect(saved.isOk, isTrue);

      final loaded = await store.load('peer-1');
      expect(loaded.isOk, isTrue);
      expect(loaded.unwrap(), orderedEquals(state));

      final reopened = SecureE2eSessionStore(keyStore, scope: 'user-a');
      final loadedAgain = await reopened.load('peer-1');
      expect(loadedAgain.isOk, isTrue);
      expect(loadedAgain.unwrap(), orderedEquals(state));
    });

    test('isolates sessions by identity scope', () async {
      final keyStore = MemorySecureKeyStore();
      final first = SecureE2eSessionStore(keyStore, scope: 'user-a');
      await first.save('peer-1', Uint8List.fromList(<int>[1, 2, 3]));

      final second = SecureE2eSessionStore(keyStore, scope: 'user-b');
      final loaded = await second.load('peer-1');
      expect(loaded.isOk, isTrue);
      expect(loaded.unwrap(), isNull);
    });

    test(
      'missing vault key reports corruption without leaking state',
      () async {
        final keyStore = MemorySecureKeyStore();
        final store = SecureE2eSessionStore(keyStore, scope: 'user-a');
        await store.save('peer-1', Uint8List.fromList(<int>[9, 8, 7]));
        await keyStore.deleteKey('opensink_state_vault_v1');

        final loaded = await store.load('peer-1');
        expect(loaded.isErr, isTrue);
        expect(loaded.unwrapErr(), isA<E2eSessionStoreCorrupted>());
      },
    );
  });
}
