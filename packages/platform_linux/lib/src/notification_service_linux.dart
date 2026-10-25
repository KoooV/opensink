import 'dart:io';

import 'package:core_domain/core_domain.dart';

/// Результат вызова системной команды уведомлений.
class NotificationCommandResult {
  const NotificationCommandResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Запуск внешней команды; подменяется в тестах.
typedef NotificationCommandRunner = Future<NotificationCommandResult> Function(
  String executable,
  List<String> arguments,
);

Future<NotificationCommandResult> _runProcess(
  String executable,
  List<String> arguments,
) async {
  final result = await Process.run(executable, arguments);
  return NotificationCommandResult(
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  );
}

/// OS-уведомления Linux через `notify-send` (libnotify/freedesktop).
///
/// Если `notify-send` отсутствует или завершился ошибкой, `show` возвращает
/// `false`, и приложение показывает in-app fallback. Отмена выполняется через
/// D-Bus `CloseNotification` по id, который вернул `notify-send --print-id`.
class LinuxNotificationBackend implements SystemNotificationBackend {
  LinuxNotificationBackend({NotificationCommandRunner? runner})
    : _runner = runner ?? _runProcess;

  static const String _notifySend = 'notify-send';
  static const String _gdbus = 'gdbus';

  final NotificationCommandRunner _runner;
  final Map<String, int> _active = <String, int>{};
  bool _available = false;

  @override
  Future<bool> show(ChatNotification notification) async {
    if (notification.id.isEmpty) return false;
    if (!await _ensureAvailable()) return false;
    final result = await _runner(_notifySend, <String>[
      '--print-id',
      '--app-name=OpenSink',
      '--urgency=normal',
      '--expire-time=4000',
      'OpenSink',
      notification.preview,
    ]);
    if (result.exitCode != 0) return false;
    final id = int.tryParse(result.stdout.trim());
    if (id == null) {
      _active.remove(notification.id);
      return true;
    }
    _active[notification.id] = id;
    return true;
  }

  @override
  Future<void> cancel(String id) async {
    final nativeId = _active.remove(id);
    if (nativeId == null) return;
    try {
      await _runner(_gdbus, <String>[
        'call',
        '--session',
        '--dest',
        'org.freedesktop.Notifications',
        '--object-path',
        '/org/freedesktop/Notifications',
        '--method',
        'org.freedesktop.Notifications.CloseNotification',
        '$nativeId',
      ]);
    } catch (_) {
      // Best-effort: просроченное уведомление исчезнет само.
    }
  }

  @override
  Future<void> cancelAll() async {
    final ids = List<int>.of(_active.values);
    _active.clear();
    for (final nativeId in ids) {
      try {
        await _runner(_gdbus, <String>[
          'call',
          '--session',
          '--dest',
          'org.freedesktop.Notifications',
          '--object-path',
          '/org/freedesktop/Notifications',
          '--method',
          'org.freedesktop.Notifications.CloseNotification',
          '$nativeId',
        ]);
      } catch (_) {
        // Best-effort.
      }
    }
  }

  Future<bool> _ensureAvailable() async {
    if (_available) return true;
    _available = await _probe();
    return _available;
  }

  Future<bool> _probe() async {
    try {
      final result = await _runner(_notifySend, <String>['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
