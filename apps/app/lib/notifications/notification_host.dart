import 'dart:async';

import 'package:core_domain/core_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di/providers.dart';

/// Показывает входящие [ChatNotification] как SnackBar.
class NotificationHost extends ConsumerStatefulWidget {
  const NotificationHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NotificationHost> createState() => _NotificationHostState();
}

class _NotificationHostState extends ConsumerState<NotificationHost> {
  StreamSubscription<ChatNotification>? _subscription;
  final Set<String> _presented = <String>{};

  @override
  void initState() {
    super.initState();
    final service = ref.read(inAppNotificationServiceProvider);
    _subscription = service.incoming.listen(_present);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final notification in service.active) {
        _present(notification);
      }
    });
  }

  void _present(ChatNotification notification) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    if (!_presented.add(notification.id)) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          notification.kind == ChatNotificationKind.mention
              ? 'Упоминание: ${notification.preview}'
              : notification.preview,
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
