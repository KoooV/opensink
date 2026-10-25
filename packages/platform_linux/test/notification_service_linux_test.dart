import 'package:core_domain/core_domain.dart';
import 'package:platform_linux/platform_linux.dart';
import 'package:test/test.dart';

const _notification = ChatNotification(
  id: 'g/c/m',
  groupId: GroupId('g'),
  channelId: ChannelId('c'),
  messageId: 'm',
  authorId: UserId('u'),
  preview: 'привет',
  kind: ChatNotificationKind.message,
  createdAt: 1,
);

void main() {
  test('show вызывает notify-send и запоминает id для cancel', () async {
    final calls = <(String, List<String>)>[];
    final backend = LinuxNotificationBackend(
      runner: (executable, arguments) async {
        calls.add((executable, arguments));
        if (arguments.first == '--version') {
          return const NotificationCommandResult(exitCode: 0);
        }
        return const NotificationCommandResult(exitCode: 0, stdout: '42\n');
      },
    );

    final shown = await backend.show(_notification);
    await backend.cancel(_notification.id);

    expect(shown, isTrue);
    expect(calls.first.$1, 'notify-send');
    expect(calls[1].$2, contains('привет'));
    expect(calls.last.$1, 'gdbus');
    expect(calls.last.$2.last, '42');
  });

  test('без notify-send show возвращает false и не запускает показ', () async {
    final calls = <String>[];
    final backend = LinuxNotificationBackend(
      runner: (executable, arguments) async {
        calls.add(arguments.join(' '));
        return const NotificationCommandResult(exitCode: 127);
      },
    );

    final shown = await backend.show(_notification);

    expect(shown, isFalse);
    expect(calls, ['--version']);
  });

  test('ошибка notify-send не считается показом', () async {
    final backend = LinuxNotificationBackend(
      runner: (executable, arguments) async {
        if (arguments.first == '--version') {
          return const NotificationCommandResult(exitCode: 0);
        }
        return const NotificationCommandResult(exitCode: 1);
      },
    );

    expect(await backend.show(_notification), isFalse);
  });
}
