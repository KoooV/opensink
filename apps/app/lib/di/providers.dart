import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_domain/core_domain.dart' as domain;
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
import '../group/group_invite_service.dart';
import '../group/group_secret_store.dart';
import '../group/sender_key_package_store.dart';
import '../group/sender_key_verifier.dart';
import '../notifications/chat_notification_bridge.dart';
import '../notifications/foreground_notification_service.dart';
import '../notifications/foreground_state.dart';
import '../notifications/in_app_notification_service.dart';
import '../notifications/os_notification_service.dart';
import 'notification_backend_platform.dart';
import 'secure_key_store_platform.dart';
import 'sync_links.dart';
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
///
/// Активным считается relay-capable транспорт: sync и прикладные сообщения
/// получают direct-first fallback без отдельной ветки.
final activeTransportProvider = FutureProvider.autoDispose<RelayTransport?>((
  ref,
) async {
  final groupId = await ref.watch(activeGroupIdProvider.future);
  if (groupId == null) return null;
  return ref.watch(relayTransportProvider(groupId).future);
});

/// Sync-линки активной группы.
///
/// Коннектор владеет только адаптерами; `RelayTransport` закрывает
/// `relayTransportProvider` при собственном dispose.
final syncLinkConnectorProvider = FutureProvider.autoDispose
    .family<SyncLinkConnector, GroupId>((ref, groupId) async {
      final engine = await ref.watch(syncEngineProvider.future);
      final transport = await ref.watch(relayTransportProvider(groupId).future);
      final connector = SyncLinkConnector(
        transport: transport,
        attach: engine.attach,
        detach: engine.detach,
      );
      await connector.start();
      ref.onDispose(() => unawaited(connector.close()));
      return connector;
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

/// Персистентные чанки файловых передач в общей SQLite-базе.
final blobStoreProvider = FutureProvider<BlobStore>((ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return DriftBlobStore(db);
});

/// Ограничение локального хранилища блобов (общее для устройства).
const int blobStoreQuotaBytes = 512 * 1024 * 1024;

final fileTransferServiceProvider = FutureProvider<FileTransferService>((
  ref,
) async {
  final store = await ref.watch(blobStoreProvider.future);
  final service = FileTransferServiceImpl(
    store: store,
    maxStoreBytes: blobStoreQuotaBytes,
  );
  ref.onDispose(() => unawaited(service.close()));
  return service;
});

final inAppNotificationServiceProvider = Provider<InAppNotificationService>((
  ref,
) {
  final service = InAppNotificationService();
  ref.onDispose(() => unawaited(service.close()));
  return service;
});

/// Платформенный канал OS-уведомлений.
final systemNotificationBackendProvider = Provider<SystemNotificationBackend>((
  ref,
) {
  return createPlatformNotificationBackend();
});

/// Текущая видимость приложения из lifecycle.
final foregroundStateProvider = Provider<ForegroundState>((ref) {
  final state = LifecycleForegroundState();
  ref.onDispose(state.dispose);
  return state;
});

/// OS-уведомления с in-app fallback.
final osNotificationServiceProvider = Provider<NotificationService>((ref) {
  return OsNotificationService(
    system: ref.watch(systemNotificationBackendProvider),
    fallback: ref.watch(inAppNotificationServiceProvider),
  );
});

/// Политика OS/in-app: foreground только in-app, background — OS с fallback.
final notificationServiceProvider = Provider<NotificationService>((ref) {
  return ForegroundNotificationService(
    foreground: ref.watch(foregroundStateProvider),
    system: ref.watch(osNotificationServiceProvider),
    inApp: ref.watch(inAppNotificationServiceProvider),
  );
});

final notificationRouterProvider = Provider<ChatNotificationRouter>((ref) {
  return ChatNotificationRouter(
    notifications: ref.watch(notificationServiceProvider),
  );
});

/// Канал по умолчанию до появления управления каналами в UI.
const ChannelId defaultChatChannel = ChannelId('general');

/// Локальный режим «не беспокоить» для уведомлений чата.
final chatDndProvider = StateProvider<bool>((ref) => false);

/// Production-сервис чата поверх общего `SyncEngine`.
final chatServiceProvider = FutureProvider.autoDispose
    .family<ChatService, GroupId>((ref, groupId) async {
      final engine = await ref.watch(syncEngineProvider.future);
      final identity = await ref.watch(localIdentityProvider.future);
      final service = ChatServiceImpl(
        engine: engine,
        localUser: identity.userId,
        bus: ref.watch(ephemeralChatBusProvider),
      );
      ref.onDispose(() => unawaited(service.close()));
      return service;
    });

/// Уведомления чата для группы: каналы из состояния плюс `general`.
final chatNotificationBridgeProvider = FutureProvider.autoDispose
    .family<ChatNotificationBridge, GroupId>((ref, groupId) async {
      final chat = await ref.watch(chatServiceProvider(groupId).future);
      final identity = await ref.watch(localIdentityProvider.future);
      final group = await ref.watch(groupStateProvider(groupId).future);
      final bridge = ChatNotificationBridge(
        chat: chat,
        router: ref.watch(notificationRouterProvider),
        groupId: groupId,
        currentUser: identity.userId,
        channels: <ChannelId>{defaultChatChannel, ...group.state.channelIds},
        isDnd: () => ref.read(chatDndProvider),
      );
      await bridge.start();
      ref.onDispose(() => unawaited(bridge.close()));
      return bridge;
    });

/// Уведомления активной группы; `null`, если группа не выбрана.
final activeChatNotificationsProvider =
    FutureProvider.autoDispose<ChatNotificationBridge?>((ref) async {
      final groupId = await ref.watch(activeGroupIdProvider.future);
      if (groupId == null) return null;
      return ref.watch(chatNotificationBridgeProvider(groupId).future);
    });

/// Живой снимок канала.
final chatViewProvider = StreamProvider.autoDispose
    .family<ChatView, (GroupId, ChannelId)>((ref, key) async* {
      final chat = await ref.watch(chatServiceProvider(key.$1).future);
      yield* chat.watch(key.$1, key.$2);
    });

final ephemeralChatBusProvider = Provider<EphemeralChatBus>((ref) {
  final bus = FakeEphemeralChatBus();
  ref.onDispose(() => unawaited(bus.close()));
  return bus;
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

/// Кэш/карантин sender key пакетов в защищённом хранилище.
final senderKeyPackageStoreProvider = Provider<SenderKeyPackageStore>((ref) {
  return SecureSenderKeyPackageStore(ref.watch(secureKeyStoreProvider));
});

/// Production-рассылка sender keys.
///
/// Пакеты подписываются ключом локальной identity. E2E-канал личных сообщений
/// ещё не подключён, поэтому доставка fail-closed: пакеты остаются pending и
/// повторяются через `retryPending` после появления сессии. Verified-кэш и
/// карантин работают сразу.
final groupKeyDistributorProvider =
    FutureProvider<ProductionGroupKeyDistributor>((ref) async {
      final identity = await ref.watch(localIdentityProvider.future);
      final metadata = await ref.watch(groupMetadataStoreProvider.future);
      return ProductionGroupKeyDistributor(
        localUser: identity.userId,
        signer: identity.signer,
        delivery: const E2eSenderKeyDelivery(
          channel: UnavailableSenderKeyChannel(),
        ),
        store: ref.watch(senderKeyPackageStoreProvider),
        verifier: TrustedGroupSenderKeyVerifier(metadata),
      );
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
    distributor: await ref.watch(groupKeyDistributorProvider.future),
    groupSecretStore: secretStore,
    inviteProofVerifier: verifiers,
    onGroupSecret: verifiers.rememberBytes,
  );
});

/// Выдача и приём инвайтов поверх жизненного цикла группы.
final groupInviteServiceProvider = FutureProvider<GroupInviteService>((
  ref,
) async {
  final lifecycle = await ref.watch(groupLifecycleProvider.future);
  final identity = await ref.watch(localIdentityProvider.future);
  return GroupInviteService(
    lifecycle: lifecycle,
    secretStore: ref.watch(groupSecretStoreProvider),
    signer: identity.signer,
    localUser: identity.userId,
  );
});

/// Группа для списка на главном экране.
class GroupSummary {
  const GroupSummary({
    required this.groupId,
    required this.name,
    required this.origin,
  });

  final GroupId groupId;
  final String name;
  final GroupOrigin origin;

  String get displayName {
    if (name.isNotEmpty) return name;
    final value = groupId.value;
    final short = value.length <= 8 ? value : value.substring(0, 8);
    return 'Группа $short';
  }
}

/// Доверенные группы с именами из открытого состояния.
final groupSummariesProvider = FutureProvider.autoDispose<List<GroupSummary>>((
  ref,
) async {
  final lifecycle = await ref.watch(groupLifecycleProvider.future);
  final metadataStore = await ref.watch(groupMetadataStoreProvider.future);
  await lifecycle.recoverPendingGroups();

  final listed = await metadataStore.list();
  if (listed.isErr) {
    throw StateError(
      'Не удалось загрузить список групп: ${listed.unwrapErr()}',
    );
  }

  final summaries = <GroupSummary>[];
  for (final metadata in listed.unwrap()) {
    if (!metadata.isReady) continue;
    var name = '';
    final opened = await lifecycle.open(metadata.groupId);
    if (opened.isOk) {
      final bridge = opened.unwrap();
      name = bridge.state.name;
      await bridge.close();
    }
    summaries.add(
      GroupSummary(
        groupId: metadata.groupId,
        name: name,
        origin: metadata.origin,
      ),
    );
  }
  summaries.sort((a, b) => a.displayName.compareTo(b.displayName));
  return summaries;
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
      final distributor = await ref.watch(groupKeyDistributorProvider.future);
      final verifiers = ref.watch(groupInviteProofVerifierRegistryProvider);
      await verifiers.preload(groupId);
      await distributor.restore(groupId);
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

/// Живое состояние группы для UI: текущий снимок и последующие изменения.
final groupLiveStateProvider = StreamProvider.autoDispose
    .family<domain.GroupState, GroupId>((ref, groupId) async* {
      final bridge = await ref.watch(groupSyncBridgeProvider(groupId).future);
      yield bridge.state;
      yield* bridge.watch();
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
