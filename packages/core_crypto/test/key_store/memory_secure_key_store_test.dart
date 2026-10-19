import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';

void main() {
  group('MemorySecureKeyStore', () {
    test('stores and loads identity', () async {
      final store = MemorySecureKeyStore();
      final userId = UserId('u-1');

      expect(await store.hasIdentity(userId), isFalse);

      await store.storeIdentity(
        userId,
        const IdentityBundle(
          userId: UserId('u-1'),
          publicKey: 'pk-hex',
          encryptedPrivateKey: [1, 2, 3],
          createdAt: 1000,
        ),
      );

      expect(await store.hasIdentity(userId), isTrue);
      final loaded = await store.loadIdentity(userId);
      expect(loaded, isNotNull);
      expect(loaded?.publicKey, 'pk-hex');
      expect(loaded?.encryptedPrivateKey, equals([1, 2, 3]));
      expect(loaded?.createdAt, 1000);
    });

    test('deleteIdentity removes entry', () async {
      final store = MemorySecureKeyStore();
      final userId = UserId('u-1');

      await store.storeIdentity(
        userId,
        const IdentityBundle(
          userId: UserId('u-1'),
          publicKey: 'pk',
          encryptedPrivateKey: [],
          createdAt: 1,
        ),
      );
      expect(await store.hasIdentity(userId), isTrue);

      await store.deleteIdentity(userId);
      expect(await store.hasIdentity(userId), isFalse);
      expect(await store.loadIdentity(userId), isNull);
    });

    test('loadIdentity returns null for missing user', () async {
      final store = MemorySecureKeyStore();
      expect(await store.loadIdentity(UserId('missing')), isNull);
    });

    test('multiple users are independent', () async {
      final store = MemorySecureKeyStore();
      await store.storeIdentity(
        UserId('u-1'),
        const IdentityBundle(
          userId: UserId('u-1'),
          publicKey: 'pk-1',
          encryptedPrivateKey: [1],
          createdAt: 1,
        ),
      );
      await store.storeIdentity(
        UserId('u-2'),
        const IdentityBundle(
          userId: UserId('u-2'),
          publicKey: 'pk-2',
          encryptedPrivateKey: [2],
          createdAt: 2,
        ),
      );

      expect((await store.loadIdentity(UserId('u-1')))?.publicKey, 'pk-1');
      expect((await store.loadIdentity(UserId('u-2')))?.publicKey, 'pk-2');
    });
  });
}
