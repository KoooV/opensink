import 'dart:convert';
import 'dart:typed_data';

import 'package:core_domain/core_domain.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/memory_store.dart';
import 'support/test_signer.dart';

void main() {
  group('edits and tombstones', () {
    test('edit and delete are separate immutable events', () async {
      final author = testAuthor(0);
      final store = MemorySyncEventStore();
      final engine = SyncEngineImpl(
        store: store,
        signer: TestSigner(author.value),
        localAuthor: author,
      );
      const group = GroupId('g');
      const channel = ChannelId('c');
      await engine.createGroup(group);
      final created = (await engine.postMessage(group, channel, 'v1')).unwrap();
      final edited = (await engine.editMessage(
        group,
        channel,
        created.id,
        'v2',
      )).unwrap();
      final deleted = (await engine.deleteMessage(
        group,
        channel,
        created.id,
      )).unwrap();

      expect(created.id, isNot(edited.id));
      expect(edited.id, isNot(deleted.id));
      final events = await engine.allEvents(group);
      expect(events, hasLength(4));
      final original = events.firstWhere((event) => event.id == created.id);
      expect(utf8.decode(original.payload), 'v1');

      final projection = await engine.projection(group);
      final message = projection.messages[created.id.value]!;
      expect(message.deleted, isTrue);
      expect(message.content, isEmpty);
      expect(message.edited, isTrue);
      await engine.close();
    });

    test('non-author edit is ignored by projection', () async {
      final owner = testAuthor(0);
      final member = testAuthor(1);
      final store = MemorySyncEventStore();
      final engine = SyncEngineImpl(
        store: store,
        signer: TestSigner(owner.value),
        localAuthor: owner,
      );
      const group = GroupId('g');
      const channel = ChannelId('c');
      await engine.createGroup(group);
      await engine.addMember(group, member);
      final created = (await engine.postMessage(
        group,
        channel,
        'owner text',
      )).unwrap();
      final hijack = await signedEvent(
        signer: TestSigner(member.value),
        author: member,
        groupId: group,
        hlc: Hlc(engine.lastHlc.physicalMs + 1, 0),
        kind: SyncEventKind.messageEdited,
        channelId: channel,
        targetId: created.id.value,
        payload: Uint8List.fromList(utf8.encode('hijacked')),
      );
      final result = await engine.ingest(hijack);
      expect(result.isOk, isTrue);

      final projection = await engine.projection(group);
      expect(projection.messages[created.id.value]!.content, 'owner text');
      await engine.close();
    });
  });
}
