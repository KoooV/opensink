import 'dart:async';
import 'dart:convert';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_storage/core_storage.dart';
import 'package:core_sync/core_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'secure_key_store_platform.dart';
import 'storage_backend_platform.dart';

/// DI-контейнер приложения.
///
/// Слой синхронизации подключён к реальным `DriftEventStore`,
/// `CryptoSigner` и платформенной SQLite. Остальные интерфейсы, для которых
/// ещё нет production-реализации/конфигурации, остаются fakes.

final signalingChannelProvider = Provider<SignalingChannel>((ref) {
  return FakeSignalingChannel();
});

final peerLinkProvider = Provider<PeerLink>((ref) {
  throw UnimplementedError('PeerLink требует установленного core_peer');
});

final transportProvider = Provider<Transport>((ref) {
  return FakeTransport();
});

final relayProvider = Provider<Relay>((ref) {
  return FakeRelay();
});

final mediaTopologyProvider = Provider<MediaTopology>((ref) {
  return FakeMediaTopology();
});

final storageBackendProvider = Provider<StorageBackend>((ref) {
  return createPlatformStorageBackend();
});

final openedStorageProvider = FutureProvider<OpenedStorage>((ref) async {
  final backend = ref.watch(storageBackendProvider);
  return backend.open(const StorageSpec(name: 'opensink.sqlite'));
});

final appDatabaseProvider = FutureProvider<AppDatabase>((ref) async {
  final opened = await ref.watch(openedStorageProvider.future);
  final db = AppDatabase(opened.executor);
  await db.open(
    backend: opened.info.backend,
    isPersistent: opened.info.isPersistent,
    warnings: opened.info.warnings,
  );
  return db;
});

final eventStoreProvider = FutureProvider<SyncEventStore>((ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  final store = DriftEventStore(db);
  ref.onDispose(() => unawaited(store.close()));
  return store;
});

final secureKeyStoreProvider = Provider<SecureKeyStore>((ref) {
  return createPlatformSecureKeyStore();
});

/// Локальная идентичность: Ed25519 seed в SecureKeyStore, подписчик в памяти.
class LocalIdentity {
  const LocalIdentity({required this.userId, required this.signer});

  final UserId userId;
  final Signer signer;
}

const String _currentIdentityKey = 'opensink_current_identity_v1';

final localIdentityProvider = FutureProvider<LocalIdentity>((ref) async {
  final store = ref.watch(secureKeyStoreProvider);
  final current = await store.loadKey(_currentIdentityKey);
  if (current.isOk) {
    final userId = UserId(utf8.decode(current.unwrap()));
    final bundle = await store.loadIdentity(userId);
    if (bundle.isOk) {
      final loaded = bundle.unwrap();
      return LocalIdentity(
        userId: loaded.userId,
        signer: signerFromSeed(loaded.privateSeed),
      );
    }
  }

  final identity = await generateIdentity();
  final seed = await identity.ed25519PrivateKey.extractBytes();
  final stored = await store.storeIdentity(
    identity.userId,
    IdentityBundle(
      userId: identity.userId,
      publicKey: identity.userId.value,
      privateSeed: seed,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
  if (stored.isErr) {
    throw StateError('Не удалось сохранить identity: ${stored.unwrapErr()}');
  }
  final currentStored = await store.storeKey(
    _currentIdentityKey,
    utf8.encode(identity.userId.value),
  );
  if (currentStored.isErr) {
    throw StateError(
      'Не удалось сохранить указатель identity: ${currentStored.unwrapErr()}',
    );
  }
  return LocalIdentity(
    userId: identity.userId,
    signer: CryptoSigner(identity.ed25519PrivateKey),
  );
});

final signerProvider = FutureProvider<Signer>((ref) async {
  return (await ref.watch(localIdentityProvider.future)).signer;
});

final syncEngineProvider = FutureProvider<SyncEngineImpl>((ref) async {
  final store = await ref.watch(eventStoreProvider.future);
  final identity = await ref.watch(localIdentityProvider.future);
  final engine = SyncEngineImpl(
    store: store,
    signer: identity.signer,
    localAuthor: identity.userId,
  );
  ref.onDispose(() => unawaited(engine.close()));
  return engine;
});

final groupStateProvider = Provider<IGroupState>((ref) {
  final initial = GroupState(
    id: const GroupId('demo'),
    name: 'Demo',
    ownerId: const UserId('me'),
    memberIds: {const UserId('me')},
    channelIds: {},
    createdAt: DateTime.now().millisecondsSinceEpoch,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );
  return FakeGroupState(initial);
});

final screenCaptureSourceProvider = Provider<ScreenCaptureSource>((ref) {
  return FakeScreenCaptureSource();
});
