import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:core_relay/core_relay.dart';
import 'package:core_signaling/core_signaling.dart' show RichSignalingChannel;
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

/// Согласие пользователя на ретрансляцию (opt-in). По умолчанию выключено.
final relayOptInProvider = Provider<bool>((ref) => false);

final relayConfigProvider = Provider<RelayConfig>((ref) {
  return RelayConfig(relayEnabled: ref.watch(relayOptInProvider));
});

/// Топология доверяет только presence из подписанного signaling-конверта.
final relayTopologyProvider = Provider<RelayTopology>((ref) {
  final topology = RelayTopology();
  final channel = ref.watch(signalingChannelProvider);
  if (channel is RichSignalingChannel) {
    final subscription = channel.presence.listen((presence) {
      final capabilities = presence.capabilities;
      topology.applyPresence(
        presence.peerId,
        neighbors: capabilities.neighbors,
        canRelay: capabilities.canRelay,
        capacityBytesPerSecond: capabilities.capacityBytesPerSecond,
      );
    });
    ref.onDispose(() => unawaited(subscription.cancel()));
  }
  return topology;
});

/// Локальная статистика прямого линка для оценки RTT в релейной топологии.
final relayLinkStatsProvider = Provider<PeerLinkStats? Function(PeerId)>((ref) {
  return ref.watch(transportProvider).statsFor;
});

final relayTransportProvider = FutureProvider<RelayTransport>((ref) async {
  final identity = await ref.watch(localIdentityProvider.future);
  final relay = RelayTransport(
    localPeerId: PeerId(Uint8List.fromList(hexToBytes(identity.userId.value))),
    direct: ref.watch(transportProvider),
    topology: ref.watch(relayTopologyProvider),
    signer: identity.signer,
    config: ref.watch(relayConfigProvider),
    linkStats: ref.watch(relayLinkStatsProvider),
  );
  ref.onDispose(() => unawaited(relay.close()));
  return relay;
});

final relayProvider = FutureProvider<Relay>((ref) async {
  final transport = await ref.watch(relayTransportProvider.future);
  return MemberRelay(
    transport: transport,
    topology: ref.watch(relayTopologyProvider),
  );
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

/// Доставка sender keys. Production-реализация появится вместе с E2E-личными
/// сообщениями; пока используется in-memory fake из `core_group`.
final groupKeyDistributorProvider = Provider<GroupKeyDistributor>((ref) {
  return InMemoryGroupKeyDistributor();
});

/// Доверенные метаданные групп (genesis, активная группа).
final groupMetadataStoreProvider = FutureProvider<GroupMetadataStore>((
  ref,
) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return DriftGroupMetadataStore(db);
});

/// Создание, join и открытие групп по сохранённому корню.
///
/// `inviteProofVerifier` не подключён до появления хранилища `GroupSecret`
/// (Q39): `joinFromInvite` явно возвращает `GroupInviteUnsupported`.
final groupLifecycleProvider = FutureProvider<GroupLifecycle>((ref) async {
  final engine = await ref.watch(syncEngineProvider.future);
  final metadataStore = await ref.watch(groupMetadataStoreProvider.future);
  return GroupLifecycle(
    syncEngine: engine,
    metadataStore: metadataStore,
    distributor: ref.watch(groupKeyDistributorProvider),
  );
});

/// Активная группа. Загружается из метаданных, по умолчанию отсутствует.
class ActiveGroupController extends AsyncNotifier<GroupId?> {
  @override
  Future<GroupId?> build() async {
    final lifecycle = await ref.watch(groupLifecycleProvider.future);
    final loaded = await lifecycle.loadActiveGroup();
    if (loaded.isErr) {
      throw StateError(
        'Не удалось загрузить активную группу: ${loaded.unwrapErr()}',
      );
    }
    return loaded.unwrap();
  }

  Future<void> select(GroupId? groupId) async {
    final lifecycle = await ref.read(groupLifecycleProvider.future);
    final saved = await lifecycle.setActiveGroup(groupId);
    if (saved.isErr) {
      throw StateError(
        'Не удалось сохранить активную группу: ${saved.unwrapErr()}',
      );
    }
    final previous = state.value;
    state = AsyncData(groupId);
    if (previous != null && previous != groupId) {
      ref.invalidate(groupSyncBridgeProvider(previous));
    }
  }
}

final activeGroupIdProvider =
    AsyncNotifierProvider<ActiveGroupController, GroupId?>(
      ActiveGroupController.new,
    );

/// Ошибка открытия группы для UI.
class GroupOpenException implements Exception {
  const GroupOpenException(this.error);

  final GroupLifecycleError error;

  @override
  String toString() => 'GroupOpenException($error)';
}

/// Мост группы, открытый по доверенным метаданным.
///
/// Никакого выбора genesis из лога и автосоздания: группа должна быть
/// создана через `GroupLifecycle.createGroup` или открыта по инвайту.
final groupSyncBridgeProvider = FutureProvider.autoDispose
    .family<GroupSyncBridge, GroupId>((ref, groupId) async {
      final lifecycle = await ref.watch(groupLifecycleProvider.future);
      GroupSyncBridge? bridge;
      var disposed = false;
      ref.onDispose(() {
        disposed = true;
        final opened = bridge;
        if (opened != null) unawaited(opened.close());
      });

      final opened = await lifecycle.open(groupId);
      if (opened.isErr) {
        throw GroupOpenException(opened.unwrapErr());
      }
      final value = opened.unwrap();
      bridge = value;
      if (disposed) {
        await value.close();
        throw StateError('group bridge was disposed during open');
      }
      return value;
    });

final groupStateProvider = FutureProvider.autoDispose
    .family<IGroupState, GroupId>((ref, groupId) async {
      return ref.watch(groupSyncBridgeProvider(groupId).future);
    });

final screenCaptureSourceProvider = Provider<ScreenCaptureSource>((ref) {
  return FakeScreenCaptureSource();
});
