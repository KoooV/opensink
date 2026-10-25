import 'package:app/notifications/foreground_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('null/resumed/inactive считаются foreground', () {
    expect(isForegroundLifecycle(null), isTrue);
    expect(isForegroundLifecycle(AppLifecycleState.resumed), isTrue);
    expect(isForegroundLifecycle(AppLifecycleState.inactive), isTrue);
  });

  test('hidden/paused/detached считаются background', () {
    expect(isForegroundLifecycle(AppLifecycleState.hidden), isFalse);
    expect(isForegroundLifecycle(AppLifecycleState.paused), isFalse);
    expect(isForegroundLifecycle(AppLifecycleState.detached), isFalse);
  });
}
