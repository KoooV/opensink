import 'package:test/test.dart';

import 'package:core_storage/core_storage.dart';
import 'memory_database.dart';

void main() {
  group('RetentionPolicy', () {
    late AppDatabase db;
    late RetentionPolicy retention;

    setUp(() {
      db = createMemoryDatabase();
      retention = RetentionPolicy(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('expireBlobs removes expired metadata and returns count', () async {
      await db.insertBlobMeta(
        id: 'b1',
        groupId: 'g1',
        filename: 'expired.png',
        mimeType: 'image/png',
        size: 100,
        createdAt: 1000,
        expiresAt: 1000, // expired
      );
      await db.insertBlobMeta(
        id: 'b2',
        groupId: 'g1',
        filename: 'valid.png',
        mimeType: 'image/png',
        size: 200,
        createdAt: 2000,
        expiresAt: 9999999999, // not expired
      );
      await db.insertBlobMeta(
        id: 'b3',
        groupId: 'g1',
        filename: 'no-expiry.png',
        mimeType: 'image/png',
        size: 300,
        createdAt: 3000,
        expiresAt: null, // never expires
      );

      final expired = await retention.expiredBlobs(5000);
      expect(expired, hasLength(1));
      expect(expired.first['id'], 'b1');

      final deleted = await retention.expireBlobs(5000);
      expect(deleted, 1);

      final remaining = await db.selectExpiredBlobs(5000);
      expect(remaining, isEmpty);
    });


    test('run deletes blob file then metadata', () async {
      await db.insertBlobMeta(
        id: 'b1',
        groupId: 'g1',
        channelId: 'c1',
        filename: 'expired.png',
        mimeType: 'image/png',
        size: 100,
        createdAt: 1000,
        expiresAt: 1000,
      );

      final deletedFiles = <String>[];
      final result = await retention.run(
        5000,
        deleteBlob: (blob) async {
          deletedFiles.add(blob.filename);
          expect(blob.channelId, 'c1');
        },
      );

      expect(result.deleted, 1);
      expect(result.isComplete, isTrue);
      expect(deletedFiles, ['expired.png']);
      expect(await db.selectExpiredBlobs(5000), isEmpty);
    });

    test('run keeps metadata when blob deletion fails', () async {
      await db.insertBlobMeta(
        id: 'b1',
        groupId: 'g1',
        filename: 'stuck.png',
        mimeType: 'image/png',
        size: 100,
        createdAt: 1000,
        expiresAt: 1000,
      );

      final result = await retention.run(
        5000,
        deleteBlob: (_) async => throw StateError('file is locked'),
      );

      expect(result.deleted, 0);
      expect(result.isComplete, isFalse);
      expect(result.failures, hasLength(1));
      expect(result.failures.single.blob.id, 'b1');
      expect(await db.selectExpiredBlobs(5000), hasLength(1));
    });

    test('expireBlobs with no expired rows returns 0', () async {
      await db.insertBlobMeta(
        id: 'b1',
        groupId: 'g1',
        filename: 'valid.png',
        mimeType: 'image/png',
        size: 100,
        createdAt: 1000,
        expiresAt: 9999999999,
      );

      final deleted = await retention.expireBlobs(5000);
      expect(deleted, 0);
    });
  });
}
