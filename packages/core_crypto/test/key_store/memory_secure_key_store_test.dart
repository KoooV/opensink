import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'secure_key_store_contract.dart';

void main() {
  group('MemorySecureKeyStore', () {
    SecureKeyStore factory() => MemorySecureKeyStore();

    secureKeyStoreContract(factory, label: ' (Memory)');

    test('toString не раскрывает секреты хранилища', () async {
      final store = MemorySecureKeyStore();
      final secret = Uint8List(32)..fillRange(0, 32, 7);
      await store.storeIdentity(
        const UserId('u-secret'),
        IdentityBundle(
          userId: const UserId('u-secret'),
          publicKey: 'pk-secret',
          encryptedPrivateKey: secret,
          createdAt: 1,
        ),
      );

      final s = store.toString();
      expect(s, isNot(contains('77777777')));
      expect(s, isNot(contains(secret.toList().toString())));
      expect(s, contains('MemorySecureKeyStore'));
    });

    test('toString бандла не раскрывает encryptedPrivateKey', () {
      final secret = [10, 20, 30, 40];
      final bundle = IdentityBundle(
        userId: const UserId('u-b'),
        publicKey: 'pk-b',
        encryptedPrivateKey: secret,
        createdAt: 2,
      );
      final s = bundle.toString();
      expect(s, isNot(contains('10, 20, 30, 40')));
      expect(s, isNot(contains(secret.toString())));
      expect(s, contains('encryptedPrivateKeyLength=4'));
      expect(s, contains('userId=u-b'));
    });

    test('loadIdentity возвращает Err(IdentityNotFound), а не исключение, для отсутствующего ключа', () async {
      final store = MemorySecureKeyStore();
      final result = await store.loadIdentity(const UserId('missing'));
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<IdentityNotFound>());
    });
  });
}
