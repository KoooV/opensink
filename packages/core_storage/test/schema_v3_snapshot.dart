/// Минимальный дамп таблиц событий и версии из схемы v3.
///
/// TODO(verify): заменить ручной снимок выводом drift_dev schema dump после
/// закрепления drift_dev в pubspec.lock; сейчас такой версии в lock-файле нет.
const List<String> schemaV3Snapshot = [
  '''CREATE TABLE events (
    id TEXT NOT NULL PRIMARY KEY,
    group_id TEXT NOT NULL,
    author TEXT NOT NULL,
    hlc INTEGER NOT NULL,
    bytes BLOB NOT NULL,
    signature TEXT NOT NULL,
    channel_id TEXT,
    seq INTEGER
  )''',
  '''CREATE TABLE schema_info (
    id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
    version INTEGER NOT NULL
  )''',
  'CREATE INDEX idx_events_group_hlc ON events(group_id, hlc)',
  'CREATE INDEX idx_events_author_hlc ON events(author, hlc)',
  'CREATE INDEX idx_events_channel_hlc ON events(channel_id, hlc)',
];
