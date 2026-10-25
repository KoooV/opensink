import 'dart:async';

import 'package:app/di/providers.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:core_storage/core_storage.dart';
import 'package:core_sync/core_sync.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ExternalDeps {
  _ExternalDeps({
    required this.engine,
    required this.metadataStore,
    required this.store,
    required this.db,
  });

  final SyncEngineImpl engine;
  final GroupMetadataStore metadataStore;
  final DriftEventStore store;
  final AppDatabase db;

  static Future<_ExternalDeps> create() async {
    final identity = await generateIdentity();
    final executor = NativeDatabase.memory();
    final db = AppDatabase(executor);
    await db.open(backend: 'memory', isPersistent: false);
    final store = DriftEventStore(db);
    final engine = SyncEngineImpl(
      store: store,
      signer: CryptoSigner(identity.ed25519PrivateKey),
      localAuthor: identity.userId,
    );
    return _ExternalDeps(
      engine: engine,
      metadataStore: DriftGroupMetadataStore(db),
      store: store,
      db: db,
    );
  }

  Future<void> close() async {
    await engine.close();
    await store.close();
    await db.close();
  }
}

List<Override> _overridesFor(
  _ExternalDeps deps, {
  required void Function(_GateLifecycle lifecycle, GroupId groupId) onLifecycle,
}) {
  return [
    syncEngineProvider.overrideWith((ref) async => deps.engine),
    groupMetadataStoreProvider.overrideWith((ref) async => deps.metadataStore),
    groupKeyDistributorProvider.overrideWith(
      (ref) async => ProductionGroupKeyDistributor(
        localUser: const UserId('test-user'),
        delivery: const UnavailableSenderKeyDelivery(),
        store: MemorySenderKeyPackageStore(),
        verifier: _AllowAllVerifier(),
      ),
    ),
    groupLifecycleProvider.overrideWith((ref) async {
      final engine = await ref.watch(syncEngineProvider.future);
      final store = await ref.watch(groupMetadataStoreProvider.future);
      final lifecycle = _GateLifecycle(
        syncEngine: engine,
        metadataStore: store,
      );
      final created = await lifecycle.createGroup(name: 'DI group');
      onLifecycle(lifecycle, created.unwrap());
      return lifecycle;
    }),
  ];
}

class _AllowAllVerifier implements SenderKeyPackageVerifier {
  @override
  Future<Result<void, SenderKeyPackageError>> verify(
    SenderKeyPackage package,
  ) async {
    return const Ok(null);
  }
}

class _GateLifecycle extends GroupLifecycle {
  _GateLifecycle({required super.syncEngine, required super.metadataStore})
    : super(distributor: InMemoryGroupKeyDistributor());

  Completer<void>? gate;
  GroupSyncBridge? lastBridge;

  @override
  Future<Result<GroupSyncBridge, GroupLifecycleError>> open(
    GroupId groupId,
  ) async {
    final waiting = gate;
    if (waiting != null) await waiting.future;
    final result = await super.open(groupId);
    if (result.isOk) lastBridge = result.unwrap();
    return result;
  }
}

Future<bool> closes(GroupSyncBridge bridge) {
  return bridge
      .watch()
      .toList()
      .then((events) => events.isEmpty)
      .timeout(const Duration(milliseconds: 200), onTimeout: () => false);
}

void main() {
  test('dispose во время open закрывает bridge после открытия', () async {
    final deps = await _ExternalDeps.create();
    addTearDown(deps.close);
    late _GateLifecycle lifecycle;
    late GroupId groupId;
    final container = ProviderContainer(
      overrides: _overridesFor(
        deps,
        onLifecycle: (value, id) {
          lifecycle = value;
          groupId = id;
        },
      ),
    );

    await container.read(groupLifecycleProvider.future);
    lifecycle.gate = Completer<void>();
    final pending = container.read(groupStateProvider(groupId).future);
    await Future<void>.delayed(Duration.zero);

    container.dispose();
    lifecycle.gate!.complete();

    await expectLater(pending, throwsA(anything));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await closes(lifecycle.lastBridge!), isTrue);
  });

  test('autoDispose закрывает bridge после ухода подписчика', () async {
    final deps = await _ExternalDeps.create();
    addTearDown(deps.close);
    late _GateLifecycle lifecycle;
    late GroupId groupId;
    final container = ProviderContainer(
      overrides: _overridesFor(
        deps,
        onLifecycle: (value, id) {
          lifecycle = value;
          groupId = id;
        },
      ),
    );
    addTearDown(container.dispose);

    await container.read(groupLifecycleProvider.future);
    final subscription = container.listen(
      groupStateProvider(groupId),
      (_, _) {},
      fireImmediately: true,
    );
    await container.read(groupStateProvider(groupId).future);
    final bridge = lifecycle.lastBridge!;
    expect(await closes(bridge), isFalse);

    subscription.close();
    await container.pump();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(await closes(bridge), isTrue);
  });
}
