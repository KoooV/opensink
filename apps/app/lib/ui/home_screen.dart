import 'dart:async';

import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di/providers.dart';
import 'group_screen.dart';
import 'messages.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupSummariesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenSink'),
        actions: [
          IconButton(
            tooltip: 'Войти по инвайту',
            onPressed: () => unawaited(_joinGroup(context, ref)),
            icon: const Icon(Icons.group_add_outlined),
          ),
          IconButton(
            tooltip: 'Обновить',
            onPressed: () => ref.invalidate(groupSummariesProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: groups.when(
        data: (items) => items.isEmpty
            ? const _EmptyHome()
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final group = items[index];
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        group.displayName.substring(0, 1).toUpperCase(),
                      ),
                    ),
                    title: Text(group.displayName),
                    subtitle: Text(
                      group.origin == GroupOrigin.invited
                          ? 'Вход по инвайту'
                          : 'Создана на этом устройстве',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        unawaited(_openGroup(context, ref, group.groupId)),
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _HomeError(
          message: 'Не удалось загрузить группы.',
          onRetry: () => ref.invalidate(groupSummariesProvider),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_createGroup(context, ref)),
        icon: const Icon(Icons.add),
        label: const Text('Создать группу'),
      ),
    );
  }

  Future<void> _openGroup(
    BuildContext context,
    WidgetRef ref,
    GroupId groupId,
  ) {
    return _activate(context, ref, groupId);
  }

  Future<void> _createGroup(BuildContext context, WidgetRef ref) async {
    final name = await _askGroupName(context);
    if (name == null) return;
    if (name.isEmpty) {
      if (!context.mounted) return;
      _showMessage(context, 'Название группы не может быть пустым.');
      return;
    }

    final lifecycle = await ref.read(groupLifecycleProvider.future);
    final created = await lifecycle.createGroup(name: name);
    if (!context.mounted) return;
    if (created.isErr) {
      _showMessage(context, lifecycleErrorMessage(created.unwrapErr()));
      return;
    }

    final groupId = created.unwrap();
    await _activate(context, ref, groupId);
  }

  Future<void> _joinGroup(BuildContext context, WidgetRef ref) async {
    final text = await _askInviteLink(context);
    if (text == null) return;
    final parsed = InviteLink.parse(text.trim());
    if (parsed.isErr) {
      if (!context.mounted) return;
      _showMessage(context, 'Ссылка не распознана.');
      return;
    }

    final service = await ref.read(groupInviteServiceProvider.future);
    final joined = await service.join(parsed.unwrap());
    if (!context.mounted) return;
    if (joined.isErr) {
      _showMessage(context, inviteErrorMessage(joined.unwrapErr()));
      return;
    }

    final outcome = joined.unwrap();
    await _activate(context, ref, outcome.groupId);
    if (!context.mounted) return;
    if (outcome.membershipPending) {
      _showMessage(
        context,
        outcome.membershipIssue == null
            ? 'Группа добавлена. Вход завершится после загрузки истории.'
            : inviteErrorMessage(outcome.membershipIssue!),
      );
    } else if (outcome.awaitingApproval) {
      _showMessage(context, 'Заявка отправлена. Ждёт одобрения админа.');
    }
  }

  Future<void> _activate(
    BuildContext context,
    WidgetRef ref,
    GroupId groupId,
  ) async {
    try {
      await ref.read(activeGroupIdProvider.notifier).select(groupId);
    } on Object {
      if (!context.mounted) return;
      _showMessage(context, 'Не удалось выбрать группу.');
      return;
    }
    ref.invalidate(groupSummariesProvider);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => GroupScreen(groupId: groupId)),
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Групп пока нет',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Создайте группу или войдите по инвайт-ссылке.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeError extends StatelessWidget {
  const _HomeError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Повторить')),
        ],
      ),
    );
  }
}

Future<String?> _askGroupName(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _GroupNameDialog(),
  );
}

class _GroupNameDialog extends StatefulWidget {
  const _GroupNameDialog();

  @override
  State<_GroupNameDialog> createState() => _GroupNameDialogState();
}

class _GroupNameDialogState extends State<_GroupNameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String value) => Navigator.of(context).pop(value.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Новая группа'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Название',
          hintText: 'Например, команда',
        ),
        onSubmitted: _submit,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => _submit(_controller.text),
          child: const Text('Создать'),
        ),
      ],
    );
  }
}

Future<String?> _askInviteLink(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _JoinInviteDialog(),
  );
}

class _JoinInviteDialog extends StatefulWidget {
  const _JoinInviteDialog();

  @override
  State<_JoinInviteDialog> createState() => _JoinInviteDialogState();
}

class _JoinInviteDialogState extends State<_JoinInviteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Вход по инвайту'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 2,
        maxLines: 4,
        decoration: const InputDecoration(
          labelText: 'Ссылка',
          hintText: 'opensink://invite?...',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Войти'),
        ),
      ],
    );
  }
}

void _showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
