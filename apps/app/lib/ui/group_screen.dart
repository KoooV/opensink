import 'dart:async';

import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart' show InviteLink;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../di/providers.dart';
import 'messages.dart';

class GroupScreen extends ConsumerWidget {
  const GroupScreen({super.key, required this.groupId});

  final GroupId groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(groupLiveStateProvider(groupId));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          group.valueOrNull?.name.isNotEmpty == true
              ? group.valueOrNull!.name
              : 'Группа',
        ),
        actions: [
          IconButton(
            tooltip: 'Выдать инвайт',
            onPressed: group.hasValue
                ? () => unawaited(_issueInvite(context, ref))
                : null,
            icon: const Icon(Icons.link),
          ),
        ],
      ),
      body: group.when(
        data: (state) => _GroupBody(state: state, groupId: groupId),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Не удалось открыть группу.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () =>
                      ref.invalidate(groupLiveStateProvider(groupId)),
                  child: const Text('Повторить'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _issueInvite(BuildContext context, WidgetRef ref) async {
    var requireApproval = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Выдать инвайт'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ссылка содержит секрет группы. Любой, у кого она есть, сможет '
                'войти в группу. Передавайте её только доверенным людям.\n\n'
                'Срок действия: 7 дней, лимит: 10 входов.',
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Требовать одобрение'),
                subtitle: const Text('Вход появится у админов как заявка.'),
                value: requireApproval,
                onChanged: (value) => setState(() => requireApproval = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Создать ссылку'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      final bridge = await ref.read(groupSyncBridgeProvider(groupId).future);
      final service = await ref.read(groupInviteServiceProvider.future);
      final issued = await service.issue(
        groupId: groupId,
        bridge: bridge,
        mode: requireApproval ? InviteMode.approval : InviteMode.open,
      );
      if (!context.mounted) return;
      if (issued.isErr) {
        _showMessage(context, inviteErrorMessage(issued.unwrapErr()));
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => InviteLinkDialog(link: issued.unwrap()),
      );
    } on Object {
      if (!context.mounted) return;
      _showMessage(context, 'Не удалось выдать инвайт.');
    }
  }
}

class _GroupBody extends ConsumerWidget {
  const _GroupBody({required this.state, required this.groupId});

  final GroupState state;
  final GroupId groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = state.ownerId.value.isNotEmpty;
    final theme = Theme.of(context);
    final localUser = ref.watch(localIdentityProvider).valueOrNull?.userId;
    final localRole = localUser == null ? null : state.memberRoles[localUser];
    final canApprove = localRole != null && localRole.atLeast(GroupRole.admin);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ready ? state.name : 'Ожидание истории группы',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  ready
                      ? 'Участников: ${state.memberIds.length} · '
                            'Каналов: ${state.channelIds.length}'
                      : 'Группа добавлена локально. Состояние появится после '
                            'синхронизации истории.',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  'ID: ${groupId.value}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        if (ready && canApprove && state.pendingJoins.isNotEmpty)
          _PendingJoins(
            state: state,
            onApprove: (userId) => _approve(context, ref, groupId, userId),
          ),
        if (ready) ...[
          const SizedBox(height: 16),
          Text('Участники', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final member in state.memberIds)
            ListTile(
              dense: true,
              leading: CircleAvatar(
                child: Text(member.value.substring(0, 2).toUpperCase()),
              ),
              title: Text(
                member == state.ownerId
                    ? '${_shortUserId(member)} · владелец'
                    : _shortUserId(member),
              ),
            ),
        ],
      ],
    );
  }
}

class _PendingJoins extends StatelessWidget {
  const _PendingJoins({required this.state, required this.onApprove});

  final GroupState state;
  final void Function(UserId userId) onApprove;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Заявки на вход'),
          ),
          for (final userId in state.pendingJoins.keys)
            ListTile(
              dense: true,
              leading: CircleAvatar(
                child: Text(userId.value.substring(0, 2).toUpperCase()),
              ),
              title: Text(_shortUserId(userId)),
              trailing: FilledButton(
                onPressed: () => onApprove(userId),
                child: const Text('Подтвердить'),
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> _approve(
  BuildContext context,
  WidgetRef ref,
  GroupId groupId,
  UserId userId,
) async {
  try {
    final bridge = await ref.read(groupSyncBridgeProvider(groupId).future);
    final service = await ref.read(groupInviteServiceProvider.future);
    final approved = await service.approve(
      groupId: groupId,
      bridge: bridge,
      userId: userId,
    );
    if (!context.mounted) return;
    if (approved.isErr) {
      _showMessage(context, inviteErrorMessage(approved.unwrapErr()));
      return;
    }
    ref.invalidate(groupLiveStateProvider(groupId));
  } on Object {
    if (!context.mounted) return;
    _showMessage(context, 'Не удалось подтвердить заявку.');
  }
}

class InviteLinkDialog extends StatelessWidget {
  const InviteLinkDialog({super.key, required this.link});

  final InviteLink link;

  @override
  Widget build(BuildContext context) {
    final uri = link.toUriString();
    return AlertDialog(
      title: const Text('Инвайт-ссылка'),
      content: SizedBox(
        width: 280,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Любой, у кого есть ссылка, сможет войти в группу.'),
              const SizedBox(height: 12),
              Center(
                child: SizedBox.square(
                  dimension: 220,
                  child: QrImageView(
                    data: uri,
                    version: QrVersions.auto,
                    size: 220,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(uri),
              const SizedBox(height: 12),
              Text('Действует до ${_formatTime(link.expiresAt)}'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: uri));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Ссылка скопирована.')),
            );
          },
          icon: const Icon(Icons.copy),
          label: const Text('Копировать'),
        ),
      ],
    );
  }
}

String _shortUserId(UserId id) {
  final value = id.value;
  return value.length <= 8 ? value : value.substring(0, 8);
}

String _formatTime(int milliseconds) {
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.day)}.${two(time.month)}.${time.year} '
      '${two(time.hour)}:${two(time.minute)}';
}

void _showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
