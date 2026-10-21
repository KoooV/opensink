import 'package:core_domain/core_domain.dart';
import 'package:core_domain/src/interfaces/fakes.dart'
    show
        FakeSignalingChannel,
        FakeSigner,
        FakeTransport,
        FakeRelay,
        FakeMediaTopology,
        FakeEventStore,
        FakeSyncEngine,
        FakeGroupState,
        FakeScreenCaptureSource,
        FakePeerLink;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'secure_key_store_platform.dart';

/// DI-контейнер приложения.
///
/// В продакшене провайдеры связываются с реальными реализациями
/// (core_peer, core_signaling, platform_*). Для разработки и тестов —
/// in-memory fakes из core_domain.
final signalingChannelProvider = Provider<SignalingChannel>((ref) {
  return FakeSignalingChannel();
});

final signerProvider = Provider<Signer>((ref) {
  return FakeSigner();
});

final peerLinkProvider = Provider<PeerLink>((ref) {
  throw UnimplementedError('PeerLink требует реализации core_peer');
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

final eventStoreProvider = Provider<EventStore>((ref) {
  return FakeEventStore();
});

final syncEngineProvider = Provider<SyncEngine>((ref) {
  return FakeSyncEngine();
});

final groupStateProvider = Provider<IGroupState>((ref) {
  final initial = GroupState(
    id: GroupId('demo'),
    name: 'Demo',
    ownerId: UserId('me'),
    memberIds: {UserId('me')},
    channelIds: {},
    createdAt: DateTime.now().millisecondsSinceEpoch,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );
  return FakeGroupState(initial);
});

final secureKeyStoreProvider = Provider<SecureKeyStore>((ref) {
  return createPlatformSecureKeyStore();
});

final screenCaptureSourceProvider = Provider<ScreenCaptureSource>((ref) {
  return FakeScreenCaptureSource();
});


// Удобный реэкспорт fakes под нейтральным именем, чтобы не тащить
// core_domain/src/interfaces/fakes.dart в UI напрямую.
