import 'package:app/notifications/in_app_notification_service.dart';
import 'package:app/notifications/os_notification_service.dart';
import 'package:core_domain/core_domain.dart';
import 'package:flutter_test/flutter_test.dart';

const _notification = ChatNotification(
  id: 'g1/c1/m1',
  groupId: GroupId('g1'),
  channelId: ChannelId('c1'),
  messageId: 'm1',
  authorId: UserId('alice'),
  preview: 'привет',
  kind: ChatNotificationKind.message,
  createdAt: 1,
);

class _FakeSystemBackend implements SystemNotificationBackend {
  _FakeSystemBackend({this.available = true, this.throws = false});

  bool available;
  bool throws;
  final List<ChatNotification> shown = <ChatNotification>[];
  final List<String> cancelled = <String>[];
  int cancelAllCalls = 0;

  @override
  Future<bool> show(ChatNotification notification) async {
    if (throws) throw StateError('platform failure');
    if (!available) return false;
    shown.add(notification);
    return true;
  }

  @override
  Future<void> cancel(String id) async {
    cancelled.add(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
  }
}

void main() {
  test(
    'OS-доступен: системное уведомление показано, in-app не дублирует',
    () async {
      final backend = _FakeSystemBackend();
      final inApp = InAppNotificationService();
      addTearDown(inApp.close);
      final service = OsNotificationService(system: backend, fallback: inApp);

      await service.show(_notification);

      expect(backend.shown.single.id, _notification.id);
      expect(inApp.active, isEmpty);
    },
  );

  test('OS-недоступен: срабатывает in-app fallback', () async {
    final backend = _FakeSystemBackend(available: false);
    final inApp = InAppNotificationService();
    addTearDown(inApp.close);
    final service = OsNotificationService(system: backend, fallback: inApp);

    await service.show(_notification);

    expect(backend.shown, isEmpty);
    expect(inApp.active.single.id, _notification.id);
  });

  test('исключение backend не теряет уведомление', () async {
    final backend = _FakeSystemBackend(throws: true);
    final inApp = InAppNotificationService();
    addTearDown(inApp.close);
    final service = OsNotificationService(system: backend, fallback: inApp);

    await service.show(_notification);

    expect(inApp.active.single.id, _notification.id);
  });

  test('cancel и cancelAll доходят до обоих сервисов', () async {
    final backend = _FakeSystemBackend();
    final inApp = InAppNotificationService();
    addTearDown(inApp.close);
    final service = OsNotificationService(system: backend, fallback: inApp);
    await service.show(_notification);
    await inApp.show(_notification);

    await service.cancel(_notification.id);
    await service.cancelAll();

    expect(backend.cancelled, [_notification.id]);
    expect(backend.cancelAllCalls, 1);
    expect(inApp.active, isEmpty);
  });

  test('пустой id игнорируется', () async {
    final backend = _FakeSystemBackend();
    final inApp = InAppNotificationService();
    addTearDown(inApp.close);
    final service = OsNotificationService(system: backend, fallback: inApp);

    await service.show(
      const ChatNotification(
        id: '',
        groupId: GroupId('g'),
        channelId: ChannelId('c'),
        messageId: 'm',
        authorId: UserId('u'),
        preview: 'x',
        kind: ChatNotificationKind.message,
        createdAt: 0,
      ),
    );

    expect(backend.shown, isEmpty);
    expect(inApp.active, isEmpty);
  });
}
