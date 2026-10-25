import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di/providers.dart';

/// Держит bridge уведомлений активной группы подключённым к UI.
class ChatNotificationBinding extends ConsumerWidget {
  const ChatNotificationBinding({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(activeChatNotificationsProvider);
    return child;
  }
}
