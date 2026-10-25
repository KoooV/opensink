import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:core_peer/core_peer.dart' show WebRtcTransport;
import 'package:core_peer/core_peer_flutter.dart' show FlutterRtcPeerFactory;
import 'package:core_relay/core_relay.dart';
import 'package:core_signaling/core_signaling.dart';
import 'package:core_storage/core_storage.dart';
import 'package:core_sync/core_sync.dart';
import 'package:cryptography/cryptography.dart' show SecretKeyData;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../group/group_invite_proof_verifier.dart';
import '../group/group_secret_store.dart';
import 'secure_key_store_platform.dart';
import 'storage_backend_platform.dart';

/// DI-контейнер приложения.
///
/// Storage, identity, sync и сетевые порты подключены к production-реализациям.
/// `Transport` строится для конкретной группы: тема signaling выводится из её
/// `GroupSecret`, поэтому без сохранённого секрета сеть fail-closed.

final peerLinkProvider = Provider<PeerLink>((ref) {
  throw UnimplementedError('PeerLink требует установленного core_peer');
});

/// Секрет активной группы: загружается из платформенного `SecureKeyStore`.
final groupSecretProvider = FutureProvider.autoDispose
    .family<GroupSecret, GroupId>((ref, groupId) async {
      final loaded = await ref.watch(groupSecretStoreProvider).load(groupId);
      if (loaded.isErr) {
        throw StateError(
          'Не удалось загрузить GroupSecret: ${loaded.unwrapErr()}',
        );
      }
      final secret = loaded.unwrap();
      if (secret == null) {
        throw StateError('GroupSecret отсутствует для группы ${groupId.value}');
      }
      return GroupSecret(SecretKeyData(Uint8List.fromList(secret)));
    });

/// Тема signaling выводится из секрета, а не из открытого `GroupId`.
final groupTopicProvider = FutureProvider.autoDispose.family<String, GroupId>((
  ref,
  groupId,
) async {
  return (await ref.watch(groupSecretProvider(groupId).future)).topicHex();
});

final signalingSecurityProvider = FutureProvider.autoDispose
    .family<SignalingSecurityConfig, GroupId>((ref, groupId) async {
      final identity = await ref.watch(localIdentityProvider.future);
      final secret = await ref.watch(groupSecretProvider(groupId).future);
      return SignalingSecurityConfig(
        peerId: PeerId(Uint8List.fromList(hexToBytes(identity.userId.value))),
        signer: identity.signer,
        groupSecret: secret,
      );
    });

/// Реальные каналы signaling: Nostr + WebTorrent-трекеры через общий пул.
final signalingChannelProvider = FutureProvider.autoDispose
    .family<RichSignalingChannel, GroupId>((ref, groupId) async {
      final security = await ref.watch(
        signalingSecurityProvider(groupId).future,
      );
      final relayEnabled = ref.watch(relayOptInProvider);
      final capabilities = NodeCapabilities(
        platform: _signalingPlatform(),
        canRelay: relayEnabled,
        capacityBytesPerSecond: relayEnabled
            ? ref.watch(relayConfigProvider).perSourceBytesPerSecond * 4
            : 0,
      );
      final pool = SignalingChannelPool(
        channels: <RichSignalingChannel>[
          NostrSignaling(security: security, capabilities: capabilities),
          TrackerSignaling(security: security, capabilities: capabilities),
        ],
      );
      ref.onDispose(() => unawaited(pool.close()));
      return pool;
    });

/// Прямой WebRTC-транспорт группы. `start()` подписывает на входящие offer.
final transportProvider = FutureProvider.autoDispose.family<Transport, GroupId>(
  (ref, groupId) async {
    final identity = await ref.watch(localIdentityProvider.future);
    final channel = await ref.watch(signalingChannelProvider(groupId).future);
    final topic = await ref.watch(groupTopicProvider(groupId).future);
    final transport = WebRtcTransport(
      localPeerId: PeerId(
        Uint8List.fromList(hexToBytes(identity.userId.value)),
      ),
      signaling: channel,
      topic: topic,
      factory: const FlutterRtcPeerFactory(),
    );
    ref.onDispose(() => unawaited(transport.close()));
    try {
      await transport.start();
    } catch (_) {
      await transport.close();
      rethrow;
    }
    return transport;
  },
);

/// Согласие пользователя на ретрансляцию (opt-in). По умолчанию выключено.
final relayOptInProvider = Provider<bool>((ref) => false);

final relayConfigProvider = Provider<RelayConfig>((ref) {
  return RelayConfig(relayEnabled: ref.watch(relayOptInProvider));
});

/// Топология доверяет только presence из подписанного signaling-конверта.
final relayTopologyProvider = FutureProvider.autoDispose
    .family<RelayTopology, GroupId>((ref, groupId) async {
      final channel = await ref.watch(signalingChannelProvider(groupId).future);
      final topology = RelayTopology();
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
      return topology;
    });

/// Локальная статистика прямого линка для оценки RTT в релейной топологии.
final relayLinkStatsProvider = FutureProvider.autoDispose
    .family<PeerLinkStats? Function(PeerId), GroupId>((ref, groupId) async {
      final transport = await ref.watch(transportProvider(groupId).future);
      return transport.statsFor;
    });

final relayTransportProvider = FutureProvider.autoDispose
    .family<RelayTransport, GroupId>((ref, groupId) async {
      final identity = await ref.watch(localIdentityProvider.future);
      final direct = await ref.watch(transportProvider(groupId).future);
      final topology = await ref.watch(relayTopologyProvider(groupId).future);
      final linkStats = await ref.watch(relayLinkStatsProvider(groupId).future);
      final initialNeighbors = direct is WebRtcTransport
          ? direct.links.keys.toSet()
          : const <PeerId>{};
      final relay = RelayTransport(
        localPeerId: PeerId(
          Uint8List.fromList(hexToBytes(identity.userId.value)),
        ),
        direct: _BorrowedTransport(direct),
        topology: topology,
        signer: identity.signer,
        config: ref.watch(relayConfigProvider),
        initialLocalNeighbors: initialNeighbors,
        linkStats: linkStats,
      );
      ref.onDispose(() => unawaited(relay.close()));
      return relay;
    });

final relayProvider = FutureProvider.autoDispose.family<Relay, GroupId>((
  ref,
  groupId,
) async {
  final transport = await ref.watch(relayTransportProvider(groupId).future);
  final topology = await ref.watch(relayTopologyProvider(groupId).future);
  return MemberRelay(transport: transport, topology: topology);
});

/// Транспорт активной группы; `null`, если группа не выбрана.
final activeTransportProvider = FutureProvider.autoDispose<Transport?>((
  ref,
) async {
  final groupId = await ref.watch(activeGroupIdProvider.future);
  if (groupId == null) return null;
  return ref.watch(transportProvider(groupId).future);
});

SignalingPlatform _signalingPlatform() {
  if (kIsWeb) return SignalingPlatform.web;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => SignalingPlatform.android,
    TargetPlatform.linux => SignalingPlatform.linux,
    _ => SignalingPlatform.unknown,
  };
}

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

final groupSecretStoreProvider = Provider<GroupSecretStore>((ref) {
  return SecureGroupSecretStore(ref.watch(secureKeyStoreProvider));
});

final groupInviteProofVerifierRegistryProvider =
    Provider<GroupInviteProofVerifierRegistry>((ref) {
      return GroupInviteProofVerifierRegistry(
        ref.watch(groupSecretStoreProvider),
      );
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
/// Секрет группы сохраняется в `SecureKeyStore`; реестр проверяющих
/// заполняется до создания/входа и перед открытием моста.
final groupLifecycleProvider = FutureProvider<GroupLifecycle>((ref) async {
  final engine = await ref.watch(syncEngineProvider.future);
  final metadataStore = await ref.watch(groupMetadataStoreProvider.future);
  final secretStore = ref.watch(groupSecretStoreProvider);
  final verifiers = ref.watch(groupInviteProofVerifierRegistryProvider);
  return GroupLifecycle(
    syncEngine: engine,
    metadataStore: metadataStore,
    distributor: ref.watch(groupKeyDistributorProvider),
    groupSecretStore: secretStore,
    inviteProofVerifier: verifiers,
    onGroupSecret: verifiers.rememberBytes,
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
      final verifiers = ref.watch(groupInviteProofVerifierRegistryProvider);
      await verifiers.preload(groupId);
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

/// Не закрывает общий `WebRtcTransport`, которым владеет `transportProvider`.
class _BorrowedTransport implements Transport {
  const _BorrowedTransport(this._inner);

  final Transport _inner;

  @override
  Stream<PeerLinkEvent> get events => _inner.events;

  @override
  Stream<RelayDatagram> get relayIncoming => _inner.relayIncoming;

  @override
  PeerLinkStats? statsFor(PeerId peerId) => _inner.statsFor(peerId);

  @override
  Future<PeerLink> connect(PeerId peerId) => _inner.connect(peerId);

  @override
  Future<void> send(PeerId dst, List<int> bytes) => _inner.send(dst, bytes);

  @override
  Future<void> sendRelay(PeerId dst, List<int> bytes) =>
      _inner.sendRelay(dst, bytes);

  @override
  Future<void> close() async {}
}
