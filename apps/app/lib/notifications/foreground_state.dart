import 'package:flutter/widgets.dart';

/// Текущая видимость приложения для политики уведомлений.
abstract class ForegroundState {
  bool get isForeground;
}

/// `inactive` и `resumed` считаются foreground: пользователь всё ещё видит
/// приложение, поэтому OS-уведомление было бы дублем.
bool isForegroundLifecycle(AppLifecycleState? state) => switch (state) {
  null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
  AppLifecycleState.hidden ||
  AppLifecycleState.paused ||
  AppLifecycleState.detached => false,
};

/// Отслеживает [AppLifecycleState] через [WidgetsBinding].
class LifecycleForegroundState with WidgetsBindingObserver
    implements ForegroundState {
  LifecycleForegroundState({WidgetsBinding? binding})
    : _binding = binding ?? WidgetsBinding.instance {
    _foreground = isForegroundLifecycle(_binding.lifecycleState);
    _binding.addObserver(this);
  }

  final WidgetsBinding _binding;
  bool _foreground = true;

  @override
  bool get isForeground => _foreground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = isForegroundLifecycle(state);
  }

  void dispose() {
    _binding.removeObserver(this);
  }
}
