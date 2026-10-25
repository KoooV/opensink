import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

void main() {
  test('per-group blob quota is independent and blocks writes', () async {
    final store = MemoryBlobStore();
    final service = FileTransferServiceImpl(
      store: store,
      maxGroupStoreBytes: 100,
    );

    final first = Uint8List.fromList(List<int>.generate(80, (i) => i));
    final firstManifest = (await service.prepare(
      first,
      groupId: 'group-a',
    )).unwrap();
    expect((await service.seed(firstManifest, first)).isOk, isTrue);
    expect(await store.totalBytesForGroup('group-a'), 80);

    final second = Uint8List.fromList(
      List<int>.generate(80, (i) => (i + 1) & 0xff),
    );
    final secondManifest = (await service.prepare(
      second,
      groupId: 'group-a',
    )).unwrap();
    final rejected = await service.seed(secondManifest, second);
    expect(rejected.isErr, isTrue);
    expect(rejected.unwrapErr(), isA<GroupQuotaExceeded>());
    expect(await store.totalBytesForGroup('group-a'), 80);

    final other = Uint8List.fromList(
      List<int>.generate(80, (i) => (i + 2) & 0xff),
    );
    final otherManifest = (await service.prepare(
      other,
      groupId: 'group-b',
    )).unwrap();
    expect((await service.seed(otherManifest, other)).isOk, isTrue);
    expect(await store.totalBytesForGroup('group-b'), 80);
    expect(await store.totalBytes(), 160);
  });
}
