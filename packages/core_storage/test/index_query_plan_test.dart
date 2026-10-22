import 'dart:typed_data';

import 'package:core_storage/core_storage.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  test('main event queries use group/hlc and author/hlc indexes', () async {
    final executor = NativeDatabase.memory();
    final db = AppDatabase(executor);
    try {
      for (var i = 0; i < 16; i++) {
        await db.insertEvent(
          id: 'event-$i',
          groupId: 'group-${i % 2}',
          author: 'author-${i % 2}',
          hlc: i,
          bytes: Uint8List.fromList([i]),
          signature: 'sig-$i',
        );
      }

      final groupPlan = await executor.runSelect(
        'EXPLAIN QUERY PLAN SELECT id FROM events '
        'WHERE group_id = ? AND hlc BETWEEN ? AND ? ORDER BY hlc ASC',
        ['group-1', 0, 15],
      );
      final authorPlan = await executor.runSelect(
        'EXPLAIN QUERY PLAN SELECT id FROM events '
        'WHERE author = ? AND hlc BETWEEN ? AND ? ORDER BY hlc ASC',
        ['author-1', 0, 15],
      );

      expect(
        groupPlan.map((row) => row['detail'].toString()).join(' '),
        contains('idx_events_group_hlc'),
      );
      expect(
        authorPlan.map((row) => row['detail'].toString()).join(' '),
        contains('idx_events_author_hlc'),
      );
    } finally {
      await db.close();
    }
  });
}
