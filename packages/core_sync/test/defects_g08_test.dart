import 'package:core_domain/core_domain.dart';
import 'package:core_protocol/core_protocol.dart' as proto;
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/memory_store.dart';
import 'support/test_signer.dart';

void main() {
  test(
    'G-08: MembershipEvaluator не принимает расхождение payload/envelope',
    () async {
      final owner = testAuthor(1);
      final signer = TestSigner(owner.value);
      final store = MemorySyncEventStore();
      final engine = SyncEngineImpl(
        store: store,
        signer: signer,
        localAuthor: owner,
      );
      addTearDown(engine.close);
      const group = GroupId('g08');
      expect((await engine.createGroup(group)).isOk, isTrue);

      final payload = proto.GroupEvent(
        id: '',
        groupId: '',
        authorId: '',
        timestamp: 0,
        eventType: SyncEventKind.memberAdded.code,
        userId: testAuthor(2).value,
      ).toBytes();
      final mismatched = await signedEvent(
        signer: signer,
        author: owner,
        groupId: group,
        hlc: Hlc(engine.lastHlc.physicalMs + 1, 0),
        kind: SyncEventKind.memberAdded,
        targetId: testAuthor(3).value,
        payload: payload,
      );

      final result = await engine.ingest(mismatched);

      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<NotAMember>());
      expect(await engine.allEvents(group), hasLength(1));
    },
  );
}
