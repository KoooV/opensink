import 'dart:typed_data';

import 'package:app/di/providers.dart';
import 'package:app/notifications/in_app_notification_service.dart';
import 'package:app/notifications/os_notification_service.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_storage/core_storage.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'BlobStore и FileTransferService используют persistent storage',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.open(backend: 'memory', isPersistent: false);
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWith((ref) async => db)],
      );
      addTearDown(container.dispose);

      final blobStore = await container.read(blobStoreProvider.future);
      expect(blobStore, isA<DriftBlobStore>());

      final files = await container.read(fileTransferServiceProvider.future);
      final bytes = Uint8List.fromList(
        List<int>.generate(40 * 1024, (index) => index & 0xff),
      );
      final manifest = (await files.prepare(
        bytes,
        fileName: 'di.bin',
      )).unwrap();
      expect((await files.seed(manifest, bytes)).isOk, isTrue);

      final restored = (await files.readAll(manifest)).unwrap();
      expect(restored, orderedEquals(bytes));
      expect(await blobStore.totalBytes(), bytes.length);
    },
  );

  test('уведомления подключены к production-сервису, а не fake', () async {
    final inApp = InAppNotificationService();
    addTearDown(inApp.close);
    final backend = _RecordingBackend();
    final container = ProviderContainer(
      overrides: [
        inAppNotificationServiceProvider.overrideWithValue(inApp),
        systemNotificationBackendProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(container.dispose);

    final notifications = container.read(notificationServiceProvider);
    expect(notifications, isA<OsNotificationService>());

    const notification = ChatNotification(
      id: 'n1',
      groupId: GroupId('g'),
      channelId: ChannelId('c'),
      messageId: 'm1',
      authorId: UserId('u'),
      preview: 'hello',
      kind: ChatNotificationKind.mention,
      createdAt: 1,
    );
    await notifications.show(notification);
    expect(backend.shown, 1);
    expect(inApp.active, isEmpty);

    await notifications.cancel('n1');
    expect(inApp.active, isEmpty);
  });
}

class _RecordingBackend implements SystemNotificationBackend {
  int shown = 0;

  @override
  Future<bool> show(ChatNotification notification) async {
    shown++;
    return true;
  }

  @override
  Future<void> cancel(String id) async {}

  @override
  Future<void> cancelAll() async {}
}
