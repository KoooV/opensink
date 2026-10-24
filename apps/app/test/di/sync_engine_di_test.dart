import 'package:app/di/providers.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_storage/core_storage.dart';
import 'package:core_sync/core_sync.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorageBackend implements StorageBackend {
  @override
  Future<OpenedStorage> open(StorageSpec spec) async {
    final executor = NativeDatabase.memory();
    final info = await AppDatabase(executor)
        .open(backend: 'memory', isPersistent: false);
    return OpenedStorage(executor: executor, info: info);
  }
}

void main() {
  test('sync engine is wired to DriftEventStore and a real signer', () async {
    final container = ProviderContainer(
      overrides: [
        storageBackendProvider.overrideWithValue(_MemoryStorageBackend()),
        secureKeyStoreProvider.overrideWithValue(MemorySecureKeyStore()),
      ],
    );

    final engine = await container.read(syncEngineProvider.future);
    addTearDown(() async {
      await engine.close();
      container.dispose();
    });

    expect(engine, isA<SyncEngineImpl>());
    expect(await container.read(signerProvider.future), isA<CryptoSigner>());

    const group = GroupId('di-group');
    const channel = ChannelId('di-channel');
    expect((await engine.createGroup(group)).isOk, isTrue);
    expect((await engine.createChannel(group, channel)).isOk, isTrue);
    final message = await engine.postMessage(group, channel, 'hello');
    expect(message.isOk, isTrue);

    final store = await container.read(eventStoreProvider.future);
    final records = await store.groupEvents(group);
    expect(records, isNotEmpty);
    expect(records.last.id, message.unwrap().id.value);
  });
}
