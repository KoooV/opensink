import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';

Future<SyncEvent> signedEvent({
  required Signer signer,
  required UserId author,
  required GroupId groupId,
  required Hlc hlc,
  required SyncEventKind kind,
  ChannelId? channelId,
  String? targetId,
  EventId? prevId,
  Uint8List? payload,
}) async {
  final draft = SyncEvent(
    id: const EventId(''),
    groupId: groupId,
    channelId: channelId,
    authorId: author,
    hlc: hlc,
    kind: kind,
    targetId: targetId,
    prevId: prevId,
    payload: payload,
  );
  final unsigned = draft.copyWith(id: EventId(draft.computeId()));
  final signature = await signer.sign(unsigned.signedBytes());
  return unsigned.copyWith(signature: signature);
}
