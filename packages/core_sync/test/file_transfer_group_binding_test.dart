import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

class _Source implements BlobSource {
  _Source(this.peerId, this.store);

  @override
  final String peerId;
  final BlobStore store;

  @override
  Future<List<int>?> fetchChunk(String fileId, int index) =>
      store.readChunk(fileId, index);
}

void main() {
  test('seed/download биндят чанки к явному groupId', () async {
    final store = MemoryBlobStore();
    final service = FileTransferServiceImpl(store: store);
    final bytes = Uint8List.fromList(
      List<int>.generate(40 * 1024, (index) => index & 0xff),
    );
    final manifest = (await service.prepare(bytes, fileName: 'g.bin')).unwrap();

    expect(
      (await service.seed(manifest, bytes, groupId: 'group-a')).isOk,
      isTrue,
    );
    expect(await store.totalBytesForGroup('group-a'), bytes.length);

    final destination = MemoryBlobStore();
    final receiver = FileTransferServiceImpl(store: destination);
    final downloaded = await receiver.download(manifest, <BlobSource>[
      _Source('peer-a', store),
    ], groupId: 'group-a');
    expect(downloaded.isOk, isTrue);
    expect(downloaded.unwrap().completed, isTrue);
    expect(await destination.totalBytesForGroup('group-a'), bytes.length);
  });

  test('конфликт manifest.groupId и явного groupId отклоняется', () async {
    final store = MemoryBlobStore();
    final service = FileTransferServiceImpl(store: store);
    final bytes = Uint8List.fromList(const <int>[1, 2, 3, 4]);
    final manifest = (await service.prepare(
      bytes,
      groupId: 'group-a',
    )).unwrap();

    final rejected = await service.seed(manifest, bytes, groupId: 'group-b');
    expect(rejected.isErr, isTrue);
    expect(rejected.unwrapErr(), isA<InvalidManifest>());
    expect(await store.totalBytes(), 0);
  });
}
