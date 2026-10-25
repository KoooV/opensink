import 'package:app/notifications/foreground_notification_service.dart';
import 'package:app/notifications/foreground_state.dart';
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

class _FakeForegroundState implements ForegroundState {
  _FakeForegroundState(this.isForeground);

  @override
  bool isForeground;
}

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
  test('foreground: только in-app, OS не вызывается', () async {
    final backend = _FakeSystemBackend();
    final inApp = FakeNotificationService();
    final service = ForegroundNotificationService(
      foreground: _FakeForegroundState(true),
      system: OsNotificationService(system: backend, fallback: inApp),
      inApp: inApp,
    );

    await service.show(_notification);

    expect(inApp.shown.single.id, _notification.id);
    expect(backend.shown, isEmpty);
  });

  test('background: OS показан, in-app не дублирует', () async {
    final backend = _FakeSystemBackend();
    final inApp = FakeNotificationService();
    final service = ForegroundNotificationService(
      foreground: _FakeForegroundState(false),
      system: OsNotificationService(system: backend, fallback: inApp),
      inApp: inApp,
    );

    await service.show(_notification);

    expect(backend.shown.single.id, _notification.id);
    expect(inApp.shown, isEmpty);
  });

  test('background и OS недоступен: in-app fallback один раз', () async {
    final backend = _FakeSystemBackend(available: false);
    final inApp = FakeNotificationService();
    final service = ForegroundNotificationService(
      foreground: _FakeForegroundState(false),
      system: OsNotificationService(system: backend, fallback: inApp),
      inApp: inApp,
    );

    await service.show(_notification);

    expect(backend.shown, isEmpty);
    expect(inApp.shown.single.id, _notification.id);
  });

  test('background и падение OS: in-app fallback один раз', () async {
    final backend = _FakeSystemBackend(throws: true);
    final inApp = FakeNotificationService();
    final service = ForegroundNotificationService(
      foreground: _FakeForegroundState(false),
      system: OsNotificationService(system: backend, fallback: inApp),
      inApp: inApp,
    );

    await service.show(_notification);

    expect(inApp.shown.single.id, _notification.id);
  });

  test('пустой id игнорируется', () async {
    final backend = _FakeSystemBackend();
    final inApp = FakeNotificationService();
    final service = ForegroundNotificationService(
      foreground: _FakeForegroundState(true),
      system: OsNotificationService(system: backend, fallback: inApp),
      inApp: inApp,
    );

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
    expect(inApp.shown, isEmpty);
  });

  test('состояние читается на каждое уведомление', () async {
    final backend = _FakeSystemBackend();
    final inApp = FakeNotificationService();
    final foreground = _FakeForegroundState(true);
    final service = ForegroundNotificationService(
      foreground: foreground,
      system: OsNotificationService(system: backend, fallback: inApp),
      inApp: inApp,
    );

    await service.show(_notification);
    foreground.isForeground = false;
    await service.show(
      const ChatNotification(
        id: 'g1/c1/m2',
        groupId: GroupId('g1'),
        channelId: ChannelId('c1'),
        messageId: 'm2',
        authorId: UserId('alice'),
        preview: 'второе',
        kind: ChatNotificationKind.message,
        createdAt: 2,
      ),
    );

    expect(inApp.shown.single.messageId, 'm1');
    expect(backend.shown.single.messageId, 'm2');
  });

  test('cancel и cancelAll доходят до OS и in-app в foreground', () async {
    final backend = _FakeSystemBackend();
    final inApp = FakeNotificationService();
    final service = ForegroundNotificationService(
      foreground: _FakeForegroundState(true),
      system: OsNotificationService(system: backend, fallback: inApp),
      inApp: inApp,
    );

    await service.cancel(_notification.id);
    await service.cancelAll();

    expect(backend.cancelled, [_notification.id]);
    expect(backend.cancelAllCalls, 1);
    expect(inApp.cancelled, contains(_notification.id));
    expect(inApp.allCancelled, isTrue);
  });

  test('cancel и cancelAll доходят до OS и in-app в background', () async {
    final backend = _FakeSystemBackend();
    final inApp = FakeNotificationService();
    final service = ForegroundNotificationService(
      foreground: _FakeForegroundState(false),
      system: OsNotificationService(system: backend, fallback: inApp),
      inApp: inApp,
    );

    await service.cancel(_notification.id);
    await service.cancelAll();

    expect(backend.cancelled, [_notification.id]);
    expect(backend.cancelAllCalls, 1);
    expect(inApp.cancelled, contains(_notification.id));
    expect(inApp.allCancelled, isTrue);
  });
}
