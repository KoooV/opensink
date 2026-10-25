library;

/// SQL schema for OpenSink event store (current schema version 9).
///
/// All tables are created during database initialization. Migrations are
/// handled alongside schema creation.

// -------------------------------------------------------------------------
// Column names
// -------------------------------------------------------------------------
const String colId = 'id';
const String colGroupId = 'group_id';
const String colAuthor = 'author';
const String colHlc = 'hlc';
const String colBytes = 'bytes';
const String colSignature = 'signature';
const String colChannelId = 'channel_id';
const String colName = 'name';
const String colOwnerId = 'owner_id';
const String colCreatedAt = 'created_at';
const String colUpdatedAt = 'updated_at';
const String colUserId = 'user_id';
const String colJoinedAt = 'joined_at';
const String colType = 'type';
const String colCreatedBy = 'created_by';
const String colPeerId = 'peer_id';
const String colLastSeen = 'last_seen';
const String colAddress = 'address';
const String colFilename = 'filename';
const String colMimeType = 'mime_type';
const String colSize = 'size';
const String colExpiresAt = 'expires_at';
const String colMessageId = 'message_id';
const String colKey = 'key';
const String colValue = 'value';

// -------------------------------------------------------------------------
// Schema version
// -------------------------------------------------------------------------
const int schemaVersion = 9;

// -------------------------------------------------------------------------
// Migration DDL (applied in order, from current user_version to schemaVersion)
// -------------------------------------------------------------------------

/// Migration v1 → v2: group settings table.
const String migrateV1ToV2GroupSettings = '''
CREATE TABLE IF NOT EXISTS group_settings (
  id TEXT NOT NULL PRIMARY KEY,
  group_id TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
)
''';

const String migrateV1ToV2IndexGroupSettings = '''
CREATE INDEX IF NOT EXISTS idx_group_settings_group_key ON group_settings(group_id, key)
''';

/// Migration v2 → v3: replace non-deterministic (author, seq) index with
/// (author, hlc). `seq` is always NULL after insert (storage never writes it),
/// so ordering by seq is not deterministic; ordering by hlc is.
const String migrateV2ToV3DropAuthorSeqIndex = '''
DROP INDEX IF EXISTS idx_events_author_seq
''';

const String migrateV2ToV3CreateAuthorHlcIndex = '''
CREATE INDEX IF NOT EXISTS idx_events_author_hlc ON events(author, hlc)
''';

/// Migration v4 → v5: database-level append-only guard for events.
const String migrateV4ToV5EventsNoUpdate = '''
CREATE TRIGGER IF NOT EXISTS events_append_only_no_update
BEFORE UPDATE ON events
BEGIN
  SELECT RAISE(ABORT, 'events are append-only');
END
''';

const String migrateV4ToV5EventsNoDelete = '''
CREATE TRIGGER IF NOT EXISTS events_append_only_no_delete
BEFORE DELETE ON events
BEGIN
  SELECT RAISE(ABORT, 'events are append-only');
END
''';

/// Migration v5 → v6: remove the unused `seq` column.
///
/// Table rebuild is used instead of `ALTER TABLE ... DROP COLUMN` so the
/// migration does not raise the minimum SQLite version above 3.24.0.
const String migrateV5ToV6DropUpdateTrigger = '''
DROP TRIGGER IF EXISTS events_append_only_no_update
''';

const String migrateV5ToV6DropDeleteTrigger = '''
DROP TRIGGER IF EXISTS events_append_only_no_delete
''';

const String migrateV5ToV6CreateEvents = '''
CREATE TABLE events_v6 (
  id TEXT NOT NULL PRIMARY KEY,
  group_id TEXT NOT NULL,
  author TEXT NOT NULL,
  hlc INTEGER NOT NULL,
  bytes BLOB NOT NULL,
  signature TEXT NOT NULL,
  channel_id TEXT
)
''';

const String migrateV5ToV6CopyEvents = '''
INSERT INTO events_v6
  (id, group_id, author, hlc, bytes, signature, channel_id)
SELECT id, group_id, author, hlc, bytes, signature, channel_id
FROM events
''';

const String migrateV5ToV6DropEvents = 'DROP TABLE events';

const String migrateV5ToV6RenameEvents = '''
ALTER TABLE events_v6 RENAME TO events
''';

const String migrateV5ToV6GroupHlcIndex = '''
CREATE INDEX IF NOT EXISTS idx_events_group_hlc ON events(group_id, hlc)
''';

const String migrateV5ToV6AuthorHlcIndex = '''
CREATE INDEX IF NOT EXISTS idx_events_author_hlc ON events(author, hlc)
''';

const String migrateV5ToV6ChannelHlcIndex = '''
CREATE INDEX IF NOT EXISTS idx_events_channel_hlc ON events(channel_id, hlc)
''';

const String migrateV5ToV6CreateUpdateTrigger = '''
CREATE TRIGGER events_append_only_no_update
BEFORE UPDATE ON events
BEGIN
  SELECT RAISE(ABORT, 'events are append-only');
END
''';

const String migrateV5ToV6CreateDeleteTrigger = '''
CREATE TRIGGER events_append_only_no_delete
BEFORE DELETE ON events
BEGIN
  SELECT RAISE(ABORT, 'events are append-only');
END
''';

/// Migration scripts keyed by target version. Each entry runs when
/// user_version < target version, in ascending order.
final Map<int, List<String>> migrations = {
  2: [migrateV1ToV2GroupSettings, migrateV1ToV2IndexGroupSettings],
  3: [migrateV2ToV3DropAuthorSeqIndex, migrateV2ToV3CreateAuthorHlcIndex],
  // v4 закрепляет валидируемый контракт записи и не преобразует строки.
  // Старые события с пустым author сохраняются в карантине без разбора payload.
  4: [],
  // v5 запрещает UPDATE/DELETE событий на уровне SQLite.
  5: [migrateV4ToV5EventsNoUpdate, migrateV4ToV5EventsNoDelete],
  // v6 удаляет неиспользуемую колонку seq пересборкой таблицы.
  6: [
    migrateV5ToV6DropUpdateTrigger,
    migrateV5ToV6DropDeleteTrigger,
    migrateV5ToV6CreateEvents,
    migrateV5ToV6CopyEvents,
    migrateV5ToV6DropEvents,
    migrateV5ToV6RenameEvents,
    migrateV5ToV6GroupHlcIndex,
    migrateV5ToV6AuthorHlcIndex,
    migrateV5ToV6ChannelHlcIndex,
    migrateV5ToV6CreateUpdateTrigger,
    migrateV5ToV6CreateDeleteTrigger,
  ],
  // v7: отдельная очередь pending-событий, переживающая рестарт движка.
  7: [migrateV6ToV7PendingEvents, migrateV6ToV7PendingEventsIndex],
  // v8: персистентные чанки файловых передач.
  8: [migrateV7ToV8BlobTransfers],
  // v9: атрибуция блобов группе для групповых квот.
  9: [migrateV8ToV9BlobGroup, migrateV8ToV9BlobGroupIndex],
};

// -------------------------------------------------------------------------
// CREATE TABLE statements
// -------------------------------------------------------------------------
const String createEvents = '''
CREATE TABLE IF NOT EXISTS events (
  id TEXT NOT NULL PRIMARY KEY,
  group_id TEXT NOT NULL,
  author TEXT NOT NULL,
  hlc INTEGER NOT NULL,
  bytes BLOB NOT NULL,
  signature TEXT NOT NULL,
  channel_id TEXT
)
''';

const String createGroups = '''
CREATE TABLE IF NOT EXISTS groups (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  owner_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''';

const String createMembers = '''
CREATE TABLE IF NOT EXISTS members (
  group_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (group_id, user_id)
)
''';

const String createChannels = '''
CREATE TABLE IF NOT EXISTS channels (
  id TEXT NOT NULL PRIMARY KEY,
  group_id TEXT NOT NULL,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL
)
''';

const String createPeers = '''
CREATE TABLE IF NOT EXISTS peers (
  peer_id TEXT NOT NULL PRIMARY KEY,
  last_seen INTEGER NOT NULL,
  address TEXT
)
''';

const String createBlobsMeta = '''
CREATE TABLE IF NOT EXISTS blobs_meta (
  id TEXT NOT NULL PRIMARY KEY,
  group_id TEXT NOT NULL,
  channel_id TEXT,
  message_id TEXT,
  filename TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  size INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER
)
''';

const String createSyncState = '''
CREATE TABLE IF NOT EXISTS sync_state (
  key TEXT NOT NULL PRIMARY KEY,
  value BLOB NOT NULL
)
''';

const String createPendingEvents = '''
CREATE TABLE IF NOT EXISTS pending_events (
  id TEXT NOT NULL PRIMARY KEY,
  group_id TEXT NOT NULL,
  author TEXT NOT NULL,
  hlc INTEGER NOT NULL,
  bytes BLOB NOT NULL,
  signature TEXT NOT NULL,
  channel_id TEXT
)
''';

const String createPendingEventsIndex = '''
CREATE INDEX IF NOT EXISTS idx_pending_events_group_hlc
ON pending_events(group_id, hlc, id)
''';

const String migrateV6ToV7PendingEvents = createPendingEvents;

const String migrateV6ToV7PendingEventsIndex = createPendingEventsIndex;

const String createBlobTransfers = '''
CREATE TABLE IF NOT EXISTS blob_transfers (
  file_id TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  bytes BLOB NOT NULL,
  received_at INTEGER NOT NULL,
  group_id TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (file_id, chunk_index)
)
''';

const String migrateV7ToV8BlobTransfers = '''
CREATE TABLE IF NOT EXISTS blob_transfers (
  file_id TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  bytes BLOB NOT NULL,
  received_at INTEGER NOT NULL,
  PRIMARY KEY (file_id, chunk_index)
)
''';

const String createBlobTransfersGroupIndex = '''
CREATE INDEX IF NOT EXISTS idx_blob_transfers_group
ON blob_transfers(group_id)
''';

const String migrateV8ToV9BlobGroup = '''
ALTER TABLE blob_transfers ADD COLUMN group_id TEXT NOT NULL DEFAULT ''
''';

const String migrateV8ToV9BlobGroupIndex = createBlobTransfersGroupIndex;

const String createSchemaInfo = '''
CREATE TABLE IF NOT EXISTS schema_info (
  id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
  version INTEGER NOT NULL
)
''';

// -------------------------------------------------------------------------
// Indexes
// -------------------------------------------------------------------------
const List<String> indexes = [
  'CREATE INDEX IF NOT EXISTS idx_events_group_hlc ON events(group_id, hlc)',
  'CREATE INDEX IF NOT EXISTS idx_events_author_hlc ON events(author, hlc)',
  'CREATE INDEX IF NOT EXISTS idx_events_channel_hlc ON events(channel_id, hlc)',
  'CREATE INDEX IF NOT EXISTS idx_channels_group_id ON channels(group_id)',
  'CREATE INDEX IF NOT EXISTS idx_blobs_group_expires ON blobs_meta(group_id, expires_at)',
];

const String createGroupSettings = '''
CREATE TABLE IF NOT EXISTS group_settings (
  id TEXT NOT NULL PRIMARY KEY,
  group_id TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
)
''';

const String createGroupSettingsIndex = '''
CREATE INDEX IF NOT EXISTS idx_group_settings_group_key ON group_settings(group_id, key)
''';

/// All DDL statements for a fresh install at current schemaVersion.
List<String> get allDdl => [
  createEvents,
  createGroups,
  createMembers,
  createChannels,
  createPeers,
  createBlobsMeta,
  createSyncState,
  createPendingEvents,
  createBlobTransfers,
  createBlobTransfersGroupIndex,
  createSchemaInfo,
  createGroupSettings,
  ...indexes,
  createGroupSettingsIndex,
  createPendingEventsIndex,
  migrateV4ToV5EventsNoUpdate,
  migrateV4ToV5EventsNoDelete,
];
