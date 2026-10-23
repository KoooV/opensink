import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fake EncryptedStateStore для проверки контракта.
// ---------------------------------------------------------------------------

class _FakeEncryptedStateStore implements EncryptedStateStore {
  final _store = <String, Uint8List>{};

  @override
  Future<Result<Uint8List, EncryptedStateStoreError>> load(String id) async {
    final bytes = _store[id];
    if (bytes == null) {
      return const Err(StateNotFound());
    }
    return Ok(Uint8List.fromList(bytes));
  }

  @override
  Future<Result<void, EncryptedStateStoreError>> save(
    String id,
    Uint8List sealed,
  ) async {
    _store[id] = Uint8List.fromList(sealed);
    return const Ok(null);
  }
}

void main() {
  group('EncryptedStateStore контракт', () {
    test('save/load roundtrip', () async {
      final store = _FakeEncryptedStateStore();
      final sealed = Uint8List.fromList([1, 2, 3, 255, 0]);

      final saveResult = await store.save('state-1', sealed);
      expect(saveResult.isOk, isTrue);

      final loadResult = await store.load('state-1');
      expect(loadResult.isOk, isTrue);
      expect(loadResult.unwrap(), equals(sealed));
    });

    test('load отсутствующего состояния → Err(StateNotFound)', () async {
      final store = _FakeEncryptedStateStore();
      final result = await store.load('missing');
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<StateNotFound>());
    });

    test('перезапись состояния заменяет предыдущее', () async {
      final store = _FakeEncryptedStateStore();
      await store.save('state-1', Uint8List.fromList([1]));
      await store.save('state-1', Uint8List.fromList([2, 3]));

      final result = await store.load('state-1');
      expect(result.unwrap(), equals(Uint8List.fromList([2, 3])));
    });

    test('SaveLoadError варианты toString не раскрывают секреты', () {
      const unavailable = StoreUnavailable('хранилище недоступно');
      const corrupted = StoreCorrupted('повреждённые данные');
      const error = StoreError('общая ошибка');

      expect(unavailable.toString(), isNot(contains('secret')));
      expect(corrupted.toString(), isNot(contains('secret')));
      expect(error.toString(), isNot(contains('secret')));
    });
  });

  group('SecureKeyStore storeKey/loadKey/deleteKey (через Fake)', () {
    test('хранение и загрузка ключа состояния', () async {
      final store = FakeSecureKeyStore();
      final keyBytes = Uint8List(32)..fillRange(0, 32, 9);

      final saveResult = await store.storeKey('vault-v1', keyBytes);
      expect(saveResult.isOk, isTrue);

      final loadResult = await store.loadKey('vault-v1');
      expect(loadResult.isOk, isTrue);
      expect(loadResult.unwrap(), equals(keyBytes));
    });

    test('loadKey отсутствующего ключа → Err(IdentityNotFound)', () async {
      final store = FakeSecureKeyStore();
      final result = await store.loadKey('missing-key');
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<IdentityNotFound>());
    });

    test('deleteKey удаляет ключ', () async {
      final store = FakeSecureKeyStore();
      await store.storeKey('vault-v1', Uint8List.fromList([1, 2, 3]));
      await store.deleteKey('vault-v1');

      final result = await store.loadKey('vault-v1');
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<IdentityNotFound>());
    });
  });
}
