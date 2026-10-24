import 'package:core_sync/core_sync.dart';

/// Выбранный genesis-корень и число лишних `GroupCreated` в логе.
class GenesisSelection {
  const GenesisSelection({required this.genesis, required this.duplicateCount});

  final SyncEvent? genesis;
  final int duplicateCount;
}

/// Выбирает самый ранний `GroupCreated` по `(HLC, id)`.
///
/// Если genesis несколько, возвращает меньший и считает остальные дублями.
GenesisSelection selectGenesis(Iterable<SyncEvent> events) {
  SyncEvent? earliest;
  var total = 0;
  for (final event in events) {
    if (event.kind != SyncEventKind.groupCreated) continue;
    total++;
    if (earliest == null || event.compareTo(earliest) < 0) {
      earliest = event;
    }
  }
  return GenesisSelection(
    genesis: earliest,
    duplicateCount: total > 1 ? total - 1 : 0,
  );
}
