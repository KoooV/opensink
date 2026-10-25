import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/ed25519_identity.dart';
import 'support/memory_store.dart';

const _group = GroupId('layer10-readiness-group');
const _channel = ChannelId('general');

Future<
  ({Ed25519Identity identity, SyncEngineImpl engine, ChatServiceImpl chat})
>
_replica(int index, int Function() nowMs) async {
  final identity = await Ed25519Identity.create(index);
  final engine = SyncEngineImpl(
    store: MemorySyncEventStore(),
    signer: identity.signer,
    localAuthor: identity.author,
    nowMs: nowMs,
  );
  final chat = ChatServiceImpl(
    engine: engine,
    localUser: identity.author,
    nowMs: nowMs,
  );
  return (identity: identity, engine: engine, chat: chat);
}

Future<void> _syncAll(List<SyncEngineImpl> engines) async {
  for (var pass = 0; pass < 3; pass++) {
    for (final target in engines) {
      for (final source in engines) {
        if (identical(target, source)) continue;
        for (final event in await source.allEvents(_group)) {
          await target.ingest(event);
        }
      }
    }
  }
}

Future<void> _setUpGroup(List<SyncEngineImpl> engines) async {
  await engines.first.createGroup(_group);
  for (final engine in engines.skip(1)) {
    await engines.first.addMember(_group, engine.localAuthor);
  }
  await _syncAll(engines);
}

void main() {
  test('preview: миниатюра изображения генерируется и передаётся пиру', () async {
    final generator = FakeThumbnailGenerator()
      ..next = ImageThumbnail(
        bytes: Uint8List.fromList(
          List<int>.generate(4096, (index) => (index * 7 + 3) & 0xff),
        ),
        width: 128,
        height: 64,
        mimeType: 'image/jpeg',
      );
    final a = FileTransferServiceImpl(
      store: MemoryBlobStore(),
      thumbnails: generator,
    );
    final bytes = Uint8List.fromList(
      List<int>.generate(64 * 1024, (index) => index & 0xff),
    );
    final source = (await a.prepare(
      bytes,
      fileName: 'photo.png',
      mimeType: 'image/png',
    )).unwrap();
    await a.seed(source, bytes);

    final previewResult = await a.preview(source, bytes);
    expect(previewResult.isOk, isTrue);
    final thumbnail = previewResult.unwrap();
    expect(thumbnail, isNotNull);
    expect(thumbnail!.width, 128);
    expect(thumbnail.mimeType, 'image/jpeg');

    final thumbnailManifest = (await a.prepare(
      thumbnail.bytes,
      fileName: 'photo.png.thumb',
      mimeType: thumbnail.mimeType,
    )).unwrap();
    await a.seed(thumbnailManifest, thumbnail.bytes);

    final b = FileTransferServiceImpl(store: MemoryBlobStore());
    final downloaded = await b.download(thumbnailManifest, <BlobSource>[
      _StoreSource('a', a.store),
    ]);
    expect(downloaded.unwrap().completed, isTrue);
    expect(
      (await b.readAll(thumbnailManifest)).unwrap(),
      orderedEquals(thumbnail.bytes),
    );

    await a.close();
    await b.close();
  });

  test('preview: не изображение или нет генератора — null', () async {
    final generator = FakeThumbnailGenerator();
    final service = FileTransferServiceImpl(
      store: MemoryBlobStore(),
      thumbnails: generator,
    );
    final text = Uint8List.fromList(const <int>[1, 2, 3, 4]);
    final manifest = (await service.prepare(
      text,
      fileName: 'note.txt',
      mimeType: 'text/plain',
    )).unwrap();
    await service.seed(manifest, text);
    expect((await service.preview(manifest, text)).unwrap(), isNull);

    final noGenerator = FileTransferServiceImpl(store: MemoryBlobStore());
    final imageBytes = Uint8List.fromList(const <int>[9, 8, 7, 6]);
    final image = (await noGenerator.prepare(
      imageBytes,
      fileName: 'p.png',
      mimeType: 'image/png',
    )).unwrap();
    await noGenerator.seed(image, imageBytes);
    expect((await noGenerator.preview(image, imageBytes)).unwrap(), isNull);

    await service.close();
    await noGenerator.close();
  });

  test(
    '3 пира: сообщения, правка, удаление, файл 50 МиБ, целостность и докачка',
    () async {
      var now = 1000;
      int clock() => now++;
      final a = await _replica(0, clock);
      final b = await _replica(1, clock);
      final c = await _replica(2, clock);
      final engines = [a.engine, b.engine, c.engine];
      await _setUpGroup(engines);

      const size = 50 * 1024 * 1024;
      final bytes = Uint8List(size);
      for (var index = 0; index < size; index++) {
        bytes[index] = (index * 37 + 11) & 0xff;
      }
      final generator = FakeThumbnailGenerator()
        ..next = ImageThumbnail(
          bytes: Uint8List.fromList(
            List<int>.generate(8192, (index) => (index * 5 + 1) & 0xff),
          ),
          width: 256,
          height: 144,
          mimeType: 'image/jpeg',
        );

      final fileA = FileTransferServiceImpl(
        store: MemoryBlobStore(),
        thumbnails: generator,
      );
      final fileB = FileTransferServiceImpl(store: MemoryBlobStore());
      final fileC = FileTransferServiceImpl(store: MemoryBlobStore());
      final manifest = (await fileA.prepare(
        bytes,
        fileName: 'photo.png',
        mimeType: 'image/png',
      )).unwrap();
      await fileA.seed(manifest, bytes);
      await fileC.seed(manifest, bytes);

      final thumbnail = (await fileA.preview(manifest, bytes)).unwrap();
      expect(thumbnail, isNotNull);
      final thumbnailManifest = (await fileA.prepare(
        thumbnail!.bytes,
        fileName: 'photo.png.thumb',
        mimeType: thumbnail.mimeType,
      )).unwrap();
      await fileA.seed(thumbnailManifest, thumbnail.bytes);
      await fileC.seed(thumbnailManifest, thumbnail.bytes);

      final attachment = ChatAttachment(
        fileId: manifest.fileId,
        fileName: manifest.fileName,
        mimeType: manifest.mimeType,
        size: manifest.size,
        chunkSize: manifest.chunkSize,
        chunkCount: manifest.chunkCount,
        thumbnailId: thumbnailManifest.fileId,
      );

      final sent = await a.chat.send(
        _group,
        _channel,
        'файл во вложении',
        attachments: [attachment],
      );
      expect(sent.isOk, isTrue);
      final messageId = sent.unwrap().id;
      await _syncAll(engines);

      final reply = await b.chat.reply(_group, _channel, messageId, 'принял');
      expect(reply.isOk, isTrue);
      final replyId = reply.unwrap().id;
      await _syncAll(engines);

      expect(
        (await b.chat.setReaction(_group, _channel, messageId, ':+1:')).isOk,
        isTrue,
      );
      expect(
        (await c.chat.markRead(_group, _channel, replyId)).isOk,
        isTrue,
      );
      expect(
        (await a.chat.edit(_group, _channel, messageId, 'файл обновлён')).isOk,
        isTrue,
      );
      expect((await b.chat.delete(_group, _channel, replyId)).isOk, isTrue);
      await _syncAll(engines);

      for (final replica in [a, b, c]) {
        final view = await replica.chat.view(_group, _channel);
        expect(view.messages, hasLength(2));
        final original = view.messages.first;
        expect(original.id, messageId);
        expect(original.edited, isTrue);
        expect(original.content, 'файл обновлён');
        expect(original.attachments.single.thumbnailId, thumbnailManifest.fileId);
        expect(original.reactions[':+1:'], contains(b.identity.author.value));
        final deleted = view.messages.last;
        expect(deleted.id, replyId);
        expect(deleted.deleted, isTrue);
        expect(
          view.readMarkers[c.identity.author.value]?.messageId,
          replyId,
        );
      }

      final failing = _StoreSource('a', fileA.store, failAfter: 200);
      final first = await fileB.download(manifest, [failing], window: 16);
      expect(first.unwrap().completed, isFalse);
      expect(first.unwrap().received, greaterThan(0));

      final resumed = await fileB.download(
        manifest,
        [_StoreSource('c', fileC.store)],
        window: 16,
      );
      expect(resumed.unwrap().completed, isTrue);
      final restored = (await fileB.readAll(manifest)).unwrap();
      expect(restored.length, size);
      expect(restored, orderedEquals(bytes));

      final thumbnailDownload = await fileB.download(
        thumbnailManifest,
        [_StoreSource('c', fileC.store)],
      );
      expect(thumbnailDownload.unwrap().completed, isTrue);
      expect(
        (await fileB.readAll(thumbnailManifest)).unwrap(),
        orderedEquals(thumbnail.bytes),
      );

      await a.chat.close();
      await b.chat.close();
      await c.chat.close();
      await fileA.close();
      await fileB.close();
      await fileC.close();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

class _StoreSource implements BlobSource {
  _StoreSource(this.peerId, this.store, {this.failAfter});

  @override
  final String peerId;
  final BlobStore store;
  final int? failAfter;
  final Set<int> requested = <int>{};

  @override
  Future<List<int>?> fetchChunk(String fileId, int index) async {
    requested.add(index);
    if (failAfter != null && requested.length > failAfter!) return null;
    return store.readChunk(fileId, index);
  }
}
