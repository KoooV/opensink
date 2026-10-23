import 'package:core_domain/core_domain.dart';
import 'package:test/test.dart';

import 'package:core_storage/core_storage.dart';
import 'memory_database.dart';

/// Валидный hex-автор (32 байта Ed25519 = 64 hex-символа).
const String _kValidAuthor =
    '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

EventRecord _validRecord() => const EventRecord(
      id: 'event-ok',
      groupId: GroupId('group-1'),
      author: _kValidAuthor,
      payload: [1, 2, 3],
      timestamp: 1000,
      signature: 'sig-hex',
    );

void main() {
  group('DriftEventStore validation', () {
    late AppDatabase db;
    late DriftEventStore store;

    setUp(() {
      db = createMemoryDatabase();
      store = DriftEventStore(db);
    });

    tearDown(() async {
      await store.close();
    });

    test('empty author → InvalidAuthor, nothing written', () async {
      final record = _validRecord().copyWith(author: '');
      final result = await store.write(record);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidAuthor>());

      // Nothing in the database
      final found = await store.getEvent('event-ok');
      expect(found, isNull);
    });

    test('author wrong length (not 64 hex chars) → InvalidAuthor', () async {
      final record = _validRecord().copyWith(author: 'short');
      final result = await store.write(record);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidAuthor>());

      final found = await store.getEvent('event-ok');
      expect(found, isNull);
    });

    test('author non-hex → InvalidAuthor', () async {
      final record = _validRecord().copyWith(
        author: 'gg112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
      );
      final result = await store.write(record);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidAuthor>());

      final found = await store.getEvent('event-ok');
      expect(found, isNull);
    });

    test('empty id → InvalidId', () async {
      final record = _validRecord().copyWith(id: '');
      final result = await store.write(record);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidId>());

      final found = await store.getEvent('');
      expect(found, isNull);
    });

    test('id with forbidden characters → InvalidId', () async {
      final record = _validRecord().copyWith(id: 'bad id/with space');
      final result = await store.write(record);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidId>());
    });

    test('id longer than 128 chars → InvalidId', () async {
      final record = _validRecord().copyWith(
        id: List.filled(129, 'a').join(),
      );
      final result = await store.write(record);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidId>());
    });

    test('empty payload → InvalidPayload', () async {
      final record = _validRecord().copyWith(payload: const []);
      final result = await store.write(record);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<InvalidPayload>());

      final found = await store.getEvent('event-ok');
      expect(found, isNull);
    });

    test('payload too large → PayloadTooLarge', () async {
      final bigPayload = List<int>.filled(1024 * 1024 + 1, 0);
      final record = _validRecord().copyWith(payload: bigPayload);
      final result = await store.write(record);
      expect(result.isErr, isTrue);
      expect(result.unwrapErr(), isA<PayloadTooLarge>());

      final found = await store.getEvent('event-ok');
      expect(found, isNull);
    });

    test('valid record → Ok, author stored and read back', () async {
      final record = _validRecord();
      final result = await store.write(record);
      expect(result.isOk, isTrue);
      final outcome = result.unwrap();
      expect(outcome.inserted, isTrue);
      expect(outcome.duplicate, isFalse);

      final found = await store.getEvent('event-ok');
      expect(found, isNotNull);
      expect(found!.author, _kValidAuthor);
      expect(found.payload, const [1, 2, 3]);
    });

    test('duplicate write → inserted=false, duplicate=true, bytes unchanged', () async {
      const record = EventRecord(
        id: 'event-dup',
        groupId: GroupId('group-1'),
        author: _kValidAuthor,
        payload: [1],
        timestamp: 1000,
        signature: 'sig-a',
      );
      const otherRecord = EventRecord(
        id: 'event-dup',
        groupId: GroupId('group-1'),
        author: _kValidAuthor,
        payload: [9],
        timestamp: 2000,
        signature: 'sig-b',
      );

      await store.write(record);
      final second = await store.write(otherRecord);
      expect(second.isOk, isTrue);
      expect(second.unwrap().inserted, isFalse);
      expect(second.unwrap().duplicate, isTrue);

      final found = await store.getEvent('event-dup');
      expect(found, isNotNull);
      expect(found!.payload, const [1]); // original bytes preserved
    });
  });
}

// copyWith helper for EventRecord (immutable class without generated copyWith).
extension _EventRecordCopyWith on EventRecord {
  EventRecord copyWith({
    String? id,
    GroupId? groupId,
    String? author,
    List<int>? payload,
    int? timestamp,
    String? signature,
  }) {
    return EventRecord(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      author: author ?? this.author,
      payload: payload ?? this.payload,
      timestamp: timestamp ?? this.timestamp,
      signature: signature ?? this.signature,
    );
  }
}
