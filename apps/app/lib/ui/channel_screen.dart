import 'dart:async';

import 'package:core_domain/core_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di/providers.dart';

class ChannelScreen extends ConsumerStatefulWidget {
  const ChannelScreen({
    super.key,
    required this.groupId,
    required this.channelId,
  });

  final GroupId groupId;
  final ChannelId channelId;

  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_markRead());
    });
  }

  Future<void> _markRead() async {
    try {
      final bridge = await ref.read(
        chatNotificationBridgeProvider(widget.groupId).future,
      );
      await bridge.readChannel(widget.channelId);
    } on Object {
      // Ошибка read marker не должна блокировать просмотр канала.
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(chatNotificationBridgeProvider(widget.groupId));
    final view = ref.watch(
      chatViewProvider((widget.groupId, widget.channelId)),
    );
    return Scaffold(
      appBar: AppBar(title: Text('#${widget.channelId.value}')),
      body: view.when(
        data: (value) => value.messages.isEmpty
            ? const Center(child: Text('Сообщений пока нет.'))
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: value.messages.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  return _MessageTile(message: value.messages[index]);
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Не удалось загрузить канал.'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(
                  chatViewProvider((widget.groupId, widget.channelId)),
                ),
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final author = message.authorId;
    final short = author.length <= 8 ? author : author.substring(0, 8);
    return ListTile(
      dense: true,
      title: Text(short),
      subtitle: Text(
        message.deleted
            ? 'Сообщение удалено'
            : message.content.isEmpty
            ? '(вложение)'
            : message.content,
      ),
      trailing: Text(
        _formatTime(message.timestamp),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

String _formatTime(int milliseconds) {
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}
