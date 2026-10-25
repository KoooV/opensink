import 'package:core_domain/core_domain.dart' hide GroupState;
import 'package:core_group/core_group.dart';
import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

import 'support/fake_sync.dart';
import 'support/fixtures.dart';

GroupLifecycle _lifecycleFor({
  required SyncEngineImpl engine,
  required GroupMetadataStore metadataStore,
  GroupSecretStore? secretStore,
  Future<void> Function(GroupId groupId, List<int> secret)? onGroupSecret,
}) {
  return GroupLifecycle(
    syncEngine: engine,
    metadataStore: metadataStore,
    distributor: InMemoryGroupKeyDistributor(),
    inviteProofVerifier: allowAllProofs,
    groupSecretStore: secretStore,
    onGroupSecret: onGroupSecret,
  );
}

Future<InviteLink> _invite({
  required FakeIdentity owner,
  required GroupId groupId,
  required String secret,
}) {
  return InviteLink.issue(
    signer: owner.signer,
    groupId: groupId,
    genesisEventId: EventId('a' * 64),
    inviteId: 'inv-1',
    secret: secret,
    inviterId: owner.author,
    expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
  );
}

void main() {
  test('create сохраняет GroupSecret и удаляет его вместе с группой', () async {
    final owner = FakeIdentity(testUserId(1));
    final engine = SyncEngineImpl(
      store: MemorySyncEventStore(),
      signer: owner.signer,
      localAuthor: owner.author,
    );
    addTearDown(engine.close);
    final metadataStore = MemoryGroupMetadataStore();
    final secretStore = MemoryGroupSecretStore();
    final observed = <GroupId, List<int>>{};
    final lifecycle = _lifecycleFor(
      engine: engine,
      metadataStore: metadataStore,
      secretStore: secretStore,
      onGroupSecret: (groupId, secret) async {
        observed[groupId] = secret;
      },
    );

    final created = await lifecycle.createGroup(name: 'Secret');

    expect(created.isOk, isTrue);
    final groupId = created.unwrap();
    final stored = (await secretStore.load(groupId)).unwrap();
    expect(stored, isNotNull);
    expect(stored!.length, 32);
    expect(observed[groupId], stored);

    final deleted = await lifecycle.deleteGroup(groupId);

    expect(deleted.isOk, isTrue);
    expect((await secretStore.load(groupId)).unwrap(), isNull);
  });

  test('join принимает только совпадающий 32-байтный секрет', () async {
    final owner = FakeIdentity(testUserId(1));
    final bob = FakeIdentity(testUserId(2));
    final ownerEngine = SyncEngineImpl(
      store: MemorySyncEventStore(),
      signer: owner.signer,
      localAuthor: owner.author,
    );
    addTearDown(ownerEngine.close);
    final bobEngine = SyncEngineImpl(
      store: MemorySyncEventStore(),
      signer: bob.signer,
      localAuthor: bob.author,
    );
    addTearDown(bobEngine.close);
    final secretStore = MemoryGroupSecretStore();
    final lifecycle = _lifecycleFor(
      engine: bobEngine,
      metadataStore: MemoryGroupMetadataStore(),
      secretStore: secretStore,
    );
    const groupId = GroupId('invite-secret');
    final secret = List<int>.generate(32, (index) => index);
    final token = encodeGroupSecretToken(secret);

    final joined = await lifecycle.joinFromInvite(
      await _invite(owner: owner, groupId: groupId, secret: token),
    );

    expect(joined.isOk, isTrue);
    expect((await secretStore.load(groupId)).unwrap(), secret);

    final mismatch = await lifecycle.joinFromInvite(
      await _invite(
        owner: owner,
        groupId: groupId,
        secret: encodeGroupSecretToken(List<int>.filled(32, 7)),
      ),
    );
    expect(mismatch.unwrapErr(), isA<GroupInviteRejected>());

    final malformed = await lifecycle.joinFromInvite(
      await _invite(owner: owner, groupId: groupId, secret: 'secret'),
    );
    expect(malformed.unwrapErr(), isA<GroupInviteRejected>());
    expect((await secretStore.load(groupId)).unwrap(), secret);
  });
}
