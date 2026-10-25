import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di/providers.dart';

/// Держит E2E-мост активной группы подключённым независимо от экрана.
class GroupE2eBinding extends ConsumerWidget {
  const GroupE2eBinding({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(activeGroupE2eWiringProvider);
    return child;
  }
}
