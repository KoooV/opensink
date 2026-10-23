/// Минимальный дамп схемы v5: events с колонкой seq и append-only триггеры.
const List<String> schemaV5Snapshot = [
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
  '''CREATE TRIGGER events_append_only_no_update
  BEFORE UPDATE ON events
  BEGIN
    SELECT RAISE(ABORT, 'events are append-only');
  END''',
  '''CREATE TRIGGER events_append_only_no_delete
  BEFORE DELETE ON events
  BEGIN
    SELECT RAISE(ABORT, 'events are append-only');
  END''',
];
