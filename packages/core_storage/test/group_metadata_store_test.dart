import 'package:core_domain/core_domain.dart';
import 'package:core_storage/core_storage.dart';
import 'package:test/test.dart';

import 'memory_database.dart';

void main() {
  group('DriftGroupMetadataStore', () {
    late AppDatabase db;
    late DriftGroupMetadataStore store;

    setUp(() {
      db = createMemoryDatabase();
      store = DriftGroupMetadataStore(db, nowMs: () => 1000);
    });

    tearDown(() async {
      await db.close();
    });

    GroupMetadata metadata({
      String groupId = 'g1',
      String? genesis = 'gen-1',
      GroupOrigin origin = GroupOrigin.created,
    }) {
      return GroupMetadata(
        groupId: GroupId(groupId),
        genesisEventId: genesis == null ? null : EventId(genesis),
        origin: origin,
        createdAt: 10,
      );
    }

    test('save/load/list/delete roundtrip', () async {
      final first = metadata();
      final second = metadata(
        groupId: 'g2',
        genesis: 'gen-2',
        origin: GroupOrigin.invited,
      );

      expect((await store.save(first)).isOk, isTrue);
      expect((await store.save(second)).isOk, isTrue);

      final loaded = await store.load(const GroupId('g1'));
      expect(loaded.unwrap(), first);

      final listed = await store.list();
      expect(listed.unwrap(), [first, second]);

      expect((await store.delete(const GroupId('g1'))).isOk, isTrue);
      expect((await store.load(const GroupId('g1'))).unwrap(), isNull);
    });

    test('pending metadata без genesis сохраняется', () async {
      final pending = metadata(genesis: null);

      expect((await store.save(pending)).isOk, isTrue);

      final loaded = (await store.load(const GroupId('g1'))).unwrap();
      expect(loaded, pending);
      expect(loaded!.isReady, isFalse);
    });

    test('active group сохраняется и очищается', () async {
      expect((await store.loadActiveGroup()).unwrap(), isNull);

      expect((await store.saveActiveGroup(const GroupId('g1'))).isOk, isTrue);
      expect((await store.loadActiveGroup()).unwrap(), const GroupId('g1'));

      expect((await store.saveActiveGroup(null)).isOk, isTrue);
      expect((await store.loadActiveGroup()).unwrap(), isNull);
    });

    test('повреждённый JSON возвращает CorruptedGroupMetadata', () async {
      await db.upsertGroupSetting(
        id: 'broken',
        groupId: 'g1',
        key: DriftGroupMetadataStore.metadataKey,
        value: '{not-json',
        updatedAt: 1,
      );

      final loaded = await store.load(const GroupId('g1'));

      expect(loaded.isErr, isTrue);
      expect(loaded.unwrapErr(), isA<CorruptedGroupMetadata>());
    });

    test('list пропускает повреждённые и чужие записи', () async {
      final valid = metadata(groupId: 'g3', genesis: 'gen-3');
      await store.save(valid);
      await db.upsertGroupSetting(
        id: 'broken',
        groupId: 'g1',
        key: DriftGroupMetadataStore.metadataKey,
        value: '{not-json',
        updatedAt: 1,
      );
      await db.upsertGroupSetting(
        id: 'wrong',
        groupId: 'g2',
        key: DriftGroupMetadataStore.metadataKey,
        value:
            '{"version":1,"group_id":"other","genesis_event_id":"gen",'
            '"origin":"created","created_at":1}',
        updatedAt: 1,
      );

      final listed = await store.list();

      expect(listed.isOk, isTrue);
      expect(listed.unwrap(), [valid]);
    });

    test('несовпадающий group_id внутри записи отклоняется', () async {
      await db.upsertGroupSetting(
        id: 'wrong',
        groupId: 'g1',
        key: DriftGroupMetadataStore.metadataKey,
        value:
            '{"version":1,"group_id":"g2","genesis_event_id":"gen",'
            '"origin":"created","created_at":1}',
        updatedAt: 1,
      );

      final loaded = await store.load(const GroupId('g1'));

      expect(loaded.isErr, isTrue);
      expect(loaded.unwrapErr(), isA<CorruptedGroupMetadata>());
    });
  });
}
