import 'package:app/di/providers.dart';
import 'package:app/e2e/e2e_sender_key_channel.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:cryptography/cryptography.dart' as crypto_pkg;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production DI публикует identity-bound bundle и реальный канал',
    () async {
      final identity = await generateIdentity();
      final seed = await identity.ed25519PrivateKey.extractBytes();
      final container = ProviderContainer(
        overrides: <Override>[
          secureKeyStoreProvider.overrideWithValue(MemorySecureKeyStore()),
          groupMetadataStoreProvider.overrideWith(
            (ref) async => MemoryGroupMetadataStore(),
          ),
          localIdentityProvider.overrideWith(
            (ref) async => LocalIdentity(
              userId: identity.userId,
              signer: CryptoSigner(identity.ed25519PrivateKey),
              privateSeed: seed,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final sessions = await container.read(e2eSessionManagerProvider.future);
      expect(
        (sessions.publicBundle.ed25519PublicKey as crypto_pkg.SimplePublicKey)
            .bytes,
        orderedEquals(
          (identity.ed25519PublicKey as crypto_pkg.SimplePublicKey).bytes,
        ),
      );

      final distributor = await container.read(
        groupKeyDistributorProvider.future,
      );
      expect(distributor.delivery, isA<E2eSenderKeyDelivery>());
      expect(
        (distributor.delivery as E2eSenderKeyDelivery).channel,
        isA<E2eSenderKeyChannel>(),
      );
    },
  );
}
