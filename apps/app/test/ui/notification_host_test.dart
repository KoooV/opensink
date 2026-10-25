import 'package:app/di/providers.dart';
import 'package:app/notifications/in_app_notification_service.dart';
import 'package:app/notifications/notification_host.dart';
import 'package:core_domain/core_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('NotificationHost показывает входящее уведомление', (
    tester,
  ) async {
    final service = InAppNotificationService();
    addTearDown(service.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [notificationServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          home: NotificationHost(child: Scaffold(body: Text('чат'))),
        ),
      ),
    );
    await tester.pump();

    await service.show(
      const ChatNotification(
        id: 'n1',
        groupId: GroupId('g'),
        channelId: ChannelId('c'),
        messageId: 'm1',
        authorId: UserId('u'),
        preview: 'новое сообщение',
        kind: ChatNotificationKind.mention,
        createdAt: 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('новое сообщение'), findsOneWidget);
  });
}
