import 'package:app/group/group_invite_proof_verifier.dart';
import 'package:app/group/group_invite_service.dart';
import 'package:core_crypto/core_crypto.dart';
import 'package:core_domain/core_domain.dart';
import 'package:core_group/core_group.dart';
import 'package:core_storage/core_storage.dart';
import 'package:core_sync/core_sync.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _Harness {
  _Harness({
    required this.identity,
    required this.signer,
    required this.db,
    required this.store,
    required this.engine,
    required this.metadataStore,
    required this.secretStore,
    required this.lifecycle,
    required this.service,
  });

  final Identity identity;
  final CryptoSigner signer;
  final AppDatabase db;
  final DriftEventStore store;
  final SyncEngineImpl engine;
  final DriftGroupMetadataStore metadataStore;
  final MemoryGroupSecretStore secretStore;
  final GroupLifecycle lifecycle;
  final GroupInviteService service;

  static Future<_Harness> create() async {
    final identity = await generateIdentity();
    final signer = CryptoSigner(identity.ed25519PrivateKey);
    final db = AppDatabase(NativeDatabase.memory());
    await db.open(backend: 'memory', isPersistent: false);
    final store = DriftEventStore(db);
    final engine = SyncEngineImpl(
      store: store,
      signer: signer,
      localAuthor: identity.userId,
    );
    final metadataStore = DriftGroupMetadataStore(db);
    final secretStore = MemoryGroupSecretStore();
    final verifiers = GroupInviteProofVerifierRegistry(secretStore);
    final lifecycle = GroupLifecycle(
      syncEngine: engine,
      metadataStore: metadataStore,
      distributor: InMemoryGroupKeyDistributor(),
      inviteProofVerifier: verifiers,
      groupSecretStore: secretStore,
      onGroupSecret: verifiers.rememberBytes,
    );
    return _Harness(
      identity: identity,
      signer: signer,
      db: db,
      store: store,
      engine: engine,
      metadataStore: metadataStore,
      secretStore: secretStore,
      lifecycle: lifecycle,
      service: GroupInviteService(
        lifecycle: lifecycle,
        secretStore: secretStore,
        signer: signer,
        localUser: identity.userId,
      ),
    );
  }

  Future<void> close() async {
    await engine.close();
    await store.close();
    await db.close();
  }
}

Future<GroupSyncBridge> _openBridge(_Harness harness, GroupId groupId) async {
  final opened = await harness.lifecycle.open(groupId);
  expect(
    opened.isOk,
    isTrue,
    reason: '${opened.isErr ? opened.unwrapErr() : ''}',
  );
  return opened.unwrap();
}

Future<void> _transfer(_Harness from, _Harness to, GroupId groupId) async {
  final events = await from.engine.allEvents(groupId);
  for (final event in events) {
    final ingested = await to.engine.ingest(event);
    expect(ingested.isOk, isTrue, reason: '$ingested');
  }
}

void main() {
  test('issue публикует InviteIssued и отдаёт подписанную ссылку', () async {
    final owner = await _Harness.create();
    addTearDown(owner.close);
    final created = await owner.lifecycle.createGroup(name: 'Команда');
    final groupId = created.unwrap();
    final bridge = await _openBridge(owner, groupId);
    addTearDown(bridge.close);

    final issued = await owner.service.issue(groupId: groupId, bridge: bridge);
    expect(issued.isOk, isTrue);

    final link = issued.unwrap();
    expect(link.groupId, groupId);
    expect(link.genesisEventId, bridge.genesisEventId);
    expect(link.inviterId, owner.identity.userId);
    expect(await link.verifySignature(owner.signer), isTrue);

    final parsed = InviteLink.parse(link.toUriString());
    expect(parsed.isOk, isTrue);
    expect(parsed.unwrap().secret, link.secret);
    expect(parsed.unwrap().secret.length, 64);

    final events = await owner.engine.allEvents(groupId);
    final invites = events
        .where((event) => event.kind == SyncEventKind.inviteIssued)
        .toList();
    expect(invites, hasLength(1));
    final decoded = const GroupEventCodec().decode(invites.single).unwrap();
    expect(decoded, isA<InviteIssued>());
    expect((decoded as InviteIssued).inviteId, link.inviteId);
    expect(decoded.maxUses, 10);
  });

  test('issue без секрета не публикует инвайт', () async {
    final owner = await _Harness.create();
    addTearDown(owner.close);
    final created = await owner.lifecycle.createGroup(name: 'Команда');
    final groupId = created.unwrap();
    final bridge = await _openBridge(owner, groupId);
    addTearDown(bridge.close);
    await owner.secretStore.delete(groupId);

    final issued = await owner.service.issue(groupId: groupId, bridge: bridge);

    expect(issued.isErr, isTrue);
    expect(issued.unwrapErr(), isA<InviteSecretUnavailable>());
    final events = await owner.engine.allEvents(groupId);
    expect(
      events.where((event) => event.kind == SyncEventKind.inviteIssued),
      isEmpty,
    );
  });

  test(
    'join публикует MemberJoined и участник появляется у владельца',
    () async {
      final owner = await _Harness.create();
      addTearDown(owner.close);
      final created = await owner.lifecycle.createGroup(name: 'Команда');
      final groupId = created.unwrap();
      final ownerBridge = await _openBridge(owner, groupId);
      addTearDown(ownerBridge.close);
      final link = (await owner.service.issue(
        groupId: groupId,
        bridge: ownerBridge,
      )).unwrap();

      final joiner = await _Harness.create();
      addTearDown(joiner.close);
      await _transfer(owner, joiner, groupId);

      final joined = await joiner.service.join(link);

      expect(joined.isOk, isTrue);
      expect(joined.unwrap().membershipRequested, isTrue);
      expect(joined.unwrap().groupId, groupId);
      final metadata = (await joiner.metadataStore.load(groupId)).unwrap()!;
      expect(metadata.origin, GroupOrigin.invited);
      expect(metadata.genesisEventId, link.genesisEventId);
      final secret = (await joiner.secretStore.load(groupId)).unwrap();
      expect(secret, isNotNull);

      final joinEvent = (await joiner.engine.allEvents(groupId))
          .firstWhere((event) => event.kind == SyncEventKind.memberJoined);
      final updated = ownerBridge.watch().firstWhere(
        (state) => state.memberIds.contains(joiner.identity.userId),
      );
      final ingested = await owner.engine.ingest(joinEvent);
      expect(ingested.isOk, isTrue);
      await updated.timeout(const Duration(seconds: 2));
    },
  );

  test(
    'join без истории оставляет членство ожидающим, повторный вход завершает',
    () async {
      final owner = await _Harness.create();
      addTearDown(owner.close);
      final created = await owner.lifecycle.createGroup(name: 'Команда');
      final groupId = created.unwrap();
      final ownerBridge = await _openBridge(owner, groupId);
      addTearDown(ownerBridge.close);
      final link = (await owner.service.issue(
        groupId: groupId,
        bridge: ownerBridge,
      )).unwrap();

      final joiner = await _Harness.create();
      addTearDown(joiner.close);

      final pending = await joiner.service.join(link);

      expect(pending.isOk, isTrue);
      expect(pending.unwrap().membershipRequested, isFalse);
      expect(pending.unwrap().membershipIssue, isA<InviteMembershipPending>());
      expect(
        (await joiner.engine.allEvents(groupId))
            .where((event) => event.kind == SyncEventKind.memberJoined),
        isEmpty,
      );

      await _transfer(owner, joiner, groupId);
      final retried = await joiner.service.join(link);

      expect(retried.isOk, isTrue);
      expect(retried.unwrap().membershipRequested, isTrue);
      expect(
        (await joiner.engine.allEvents(groupId))
            .where((event) => event.kind == SyncEventKind.memberJoined),
        hasLength(1),
      );
    },
  );

  test('просроченная ссылка отклоняется без записи метаданных', () async {
    final owner = await _Harness.create();
    addTearDown(owner.close);
    final created = await owner.lifecycle.createGroup(name: 'Команда');
    final groupId = created.unwrap();
    final bridge = await _openBridge(owner, groupId);
    addTearDown(bridge.close);
    final metadata = (await owner.metadataStore.load(groupId)).unwrap()!;
    final secret = (await owner.secretStore.load(groupId)).unwrap()!;
    final expired = await InviteLink.issue(
      signer: owner.signer,
      groupId: groupId,
      genesisEventId: metadata.genesisEventId!,
      inviteId: 'expired-invite',
      secret: encodeGroupSecretToken(secret),
      inviterId: owner.identity.userId,
      expiresAt: DateTime.now().millisecondsSinceEpoch - 1000,
    );

    final joiner = await _Harness.create();
    addTearDown(joiner.close);
    final joined = await joiner.service.join(expired);

    expect(joined.isErr, isTrue);
    expect(joined.unwrapErr(), isA<InviteJoinFailed>());
    final error = (joined.unwrapErr() as InviteJoinFailed).error;
    expect(error, isA<GroupInviteRejected>());
    expect((await joiner.metadataStore.load(groupId)).unwrap(), isNull);
    expect((await joiner.secretStore.load(groupId)).unwrap(), isNull);
  });

  _approvalTests();
}

void _approvalTests() {
  test(
    'approval-инвайт: join ждёт подтверждения, approve добавляет участника',
    () async {
      final owner = await _Harness.create();
      addTearDown(owner.close);
      final created = await owner.lifecycle.createGroup(name: 'Закрытая');
      final groupId = created.unwrap();
      final ownerBridge = await _openBridge(owner, groupId);
      addTearDown(ownerBridge.close);
      final link = (await owner.service.issue(
        groupId: groupId,
        bridge: ownerBridge,
        mode: InviteMode.approval,
      )).unwrap();

      final joiner = await _Harness.create();
      addTearDown(joiner.close);
      await _transfer(owner, joiner, groupId);

      final joined = await joiner.service.join(link);
      expect(joined.isOk, isTrue);
      expect(joined.unwrap().awaitingApproval, isTrue);
      expect(joined.unwrap().membershipRequested, isTrue);

      final joinEvent = (await joiner.engine.allEvents(groupId))
          .firstWhere((event) => event.kind == SyncEventKind.memberJoined);
      expect((await owner.engine.ingest(joinEvent)).isOk, isTrue);
      final pending = await ownerBridge
          .watch()
          .firstWhere(
            (state) => state.pendingJoins.containsKey(joiner.identity.userId),
          )
          .timeout(const Duration(seconds: 2));
      expect(pending.memberIds, isNot(contains(joiner.identity.userId)));

      final approved = await owner.service.approve(
        groupId: groupId,
        bridge: ownerBridge,
        userId: joiner.identity.userId,
      );
      expect(approved.isOk, isTrue);

      final approveEvent = (await owner.engine.allEvents(groupId))
          .firstWhere((event) => event.kind == SyncEventKind.memberApproved);
      expect((await joiner.engine.ingest(approveEvent)).isOk, isTrue);
      final joinerBridge = await _openBridge(joiner, groupId);
      addTearDown(joinerBridge.close);
      expect(joinerBridge.state.memberIds, contains(joiner.identity.userId));
    },
  );

  test('approve без pending-заявки отклоняется', () async {
    final owner = await _Harness.create();
    addTearDown(owner.close);
    final groupId = (await owner.lifecycle.createGroup(name: 'Закрытая'))
        .unwrap();
    final bridge = await _openBridge(owner, groupId);
    addTearDown(bridge.close);

    final unknown = (await _Harness.create()).identity.userId;
    final approved = await owner.service.approve(
      groupId: groupId,
      bridge: bridge,
      userId: unknown,
    );

    expect(approved.isErr, isTrue);
    expect(approved.unwrapErr(), isA<InviteNotPending>());
  });
}
