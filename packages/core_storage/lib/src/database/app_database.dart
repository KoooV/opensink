import 'dart:convert';

import 'package:core_domain/core_domain.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import '../models/event_data.dart';
import '../models/storage_info.dart';
import 'schema.dart' as schema;
import 'schema.dart';

/// Drift-backed storage for OpenSink event store.
///
/// Wraps a QueryExecutor (native SQLite, WASM SQLite, or in-memory) and
/// executes raw SQL for all operations. No code generation is required —
/// this keeps core_storage free of platform-specific dependencies.
///
/// QueryExecutor передаётся фабрикой платформенного пакета.
class AppDatabase implements QueryExecutorUser {
  static const String minimumSqliteVersion = '3.24.0';

  /// Максимум событий, по которым строится range summary за один запрос.
  static const int maxRangeEvents = 100000;

  final QueryExecutor _executor;
  final int _schemaVersion;
  bool _isOpen = false;
  bool _schemaInitialized = false;
  bool _sqliteVersionChecked = false;
  String? _sqliteVersion;
  StorageInfo? _storageInfo;

  /// Creates an AppDatabase backed by the given executor.
  ///
  /// [version] overrides the schema version (defaults to the current
  /// [schemaVersion] from schema.dart). Used for testing migrations against
  /// older schemas.
  AppDatabase(this._executor, {int? version})
    : _schemaVersion = version ?? schema.schemaVersion;

  @override
  int get schemaVersion => _schemaVersion;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {
    // No-op: schema is ensured in [_open] after ensureOpen returns,
    // because runCustom requires the executor to be open.
  }

  /// Версия SQLite, полученная при открытии подключения.
  String? get sqliteVersion => _sqliteVersion;

  /// Сведения о последнем явном открытии через [open].
  StorageInfo? get storageInfo => _storageInfo;

  /// Открывает базу, проверяет SQLite и возвращает сведения о backend-е.
  ///
  /// [backend], [isPersistent] и [warnings] задаются вызывающим платформенным
  /// слоем; версия SQLite считывается непосредственно из executor-а.
  Future<StorageInfo> open({
    required String backend,
    required bool isPersistent,
    List<String> warnings = const [],
  }) async {
    await _open<void>(() async {});
    final info = StorageInfo(
      backend: backend,
      isPersistent: isPersistent,
      sqliteVersion: _sqliteVersion,
      warnings: warnings,
    );
    _storageInfo = info;
    return info;
  }

  /// Ensures the executor is open, SQLite is supported, and schema is ready.
  Future<T> _open<T>(Future<T> Function() action) async {
    await _ensureOpenAndSchema();
    return action();
  }

  Future<void> _ensureOpenAndSchema() async {
    try {
      if (!_isOpen) {
        await _executor.ensureOpen(this);
        _isOpen = true;
      }
      if (!_sqliteVersionChecked) {
        final rows = await _executor.runSelect(
          'SELECT sqlite_version() AS version',
          const [],
        );
        if (rows.isEmpty || rows.first['version'] == null) {
          throw const FormatException('SQLite version query returned no value');
        }
        _sqliteVersion = rows.first['version'].toString();
        _sqliteVersionChecked = true;
      }
      final actual = _sqliteVersion!;
      if (!_isVersionAtLeast(actual, minimumSqliteVersion)) {
        throw DatabaseVersionTooLow(minimumSqliteVersion, actual);
      }
      if (!_schemaInitialized) {
        await _ensureSchema();
        _schemaInitialized = true;
      }
    } on StorageOpenError {
      rethrow;
    } catch (error, stack) {
      throw OpenFailure(error, stack);
    }
  }

  static bool _isVersionAtLeast(String actual, String required) {
    List<int> parse(String value) {
      final components = value.split('.');
      if (components.length < 2 || components.length > 3) {
        throw FormatException('Invalid SQLite version: $value');
      }
      return [
        for (final component in components) int.parse(component),
        if (components.length == 2) 0,
      ];
    }

    final actualParts = parse(actual);
    final requiredParts = parse(required);
    for (var i = 0; i < 3; i++) {
      if (actualParts[i] != requiredParts[i]) {
        return actualParts[i] > requiredParts[i];
      }
    }
    return true;
  }

  /// Creates all tables and indexes for a fresh install (idempotent).
  Future<void> _createSchema() async {
    for (final ddl in allDdl) {
      await _executor.runCustom(ddl);
    }
  }

  /// Reads the stored schema version from schema_info.
  ///
  /// Returns 0 if the table is empty (fresh install, version row not yet
  /// inserted).
  Future<int> _getStoredVersion() async {
    final rows = await _executor.runSelect(
      'SELECT version FROM schema_info WHERE id = 1',
      [],
    );
    if (rows.isEmpty) return 0;
    return int.parse(rows.first['version']!.toString());
  }

  /// Writes the schema version to schema_info (upsert).
  Future<void> _setStoredVersion(int version) async {
    await _executor.runInsert(
      'INSERT INTO schema_info (id, version) VALUES (1, ?) '
      'ON CONFLICT(id) DO UPDATE SET version = ?',
      [version, version],
    );
  }

  /// Ensures schema exists, applying migrations if needed.
  ///
  /// Fresh install: create all DDL, set version = schemaVersion.
  /// Existing DB: apply migrations from current version to schemaVersion.
  Future<void> _ensureSchema() async {
    int currentVersion;
    try {
      currentVersion = await _getStoredVersion();
    } catch (e) {
      // schema_info таблицы ещё нет — это чистая установка.
      if (e.toString().contains('no such table: schema_info')) {
        currentVersion = 0;
      } else {
        rethrow;
      }
    }

    if (currentVersion == 0) {
      await _createSchema();
      await _setStoredVersion(_schemaVersion);
      return;
    }

    if (currentVersion < _schemaVersion) {
      await _migrate(currentVersion, _schemaVersion);
      return;
    }

    // currentVersion == schemaVersion: nothing to do.
    // currentVersion > schemaVersion: unknown future schema, no-op.
  }

  /// Applies migrations from (fromVersion] to [toVersion] inclusive.
  ///
  /// DDL и обновление `schema_info` выполняются одной транзакцией: сбой
  /// посередине не оставляет частично мигрированную схему.
  Future<void> _migrate(int fromVersion, int toVersion) async {
    final transaction = _executor.beginTransaction();
    try {
      await transaction.ensureOpen(this);
      for (var v = fromVersion + 1; v <= toVersion; v++) {
        final steps = migrations[v];
        if (steps == null) continue;
        for (final ddl in steps) {
          await transaction.runCustom(ddl);
        }
      }
      await transaction.runInsert(
        'INSERT INTO schema_info (id, version) VALUES (1, ?) '
        'ON CONFLICT(id) DO UPDATE SET version = ?',
        [toVersion, toVersion],
      );
      await transaction.send();
    } catch (_) {
      await transaction.rollback();
      rethrow;
    }
  }

  /// Closes the underlying executor.
  Future<void> close() async {
    if (_isOpen) {
      await _executor.close();
      _isOpen = false;
      _schemaInitialized = false;
      _sqliteVersionChecked = false;
      _sqliteVersion = null;
      _storageInfo = null;
    }
  }

  // -------------------------------------------------------------------------
  // Events
  // -------------------------------------------------------------------------

  /// Idempotent insert of an event. Duplicate id → no-op.
  ///
  /// Returns the number of affected rows: 1 if the row was inserted,
  /// 0 if a row with the same id already existed (INSERT OR IGNORE).
  ///
  /// Low-level API: production code must use `DriftEventStore.write`, which
  /// validates the record. Exposed only for storage internals and tests.
  @internal
  Future<int> insertEvent({
    required String id,
    required String groupId,
    required String author,
    required int hlc,
    required List<int> bytes,
    required String signature,
    String? channelId,
  }) async {
    return await _open(() async {
      // runInsert возвращает lastInsertRowId, который может остаться прежним
      // после INSERT OR IGNORE. runUpdate возвращает число изменённых строк.
      return await _executor.runUpdate(
        'INSERT OR IGNORE INTO events '
        '(id, group_id, author, hlc, bytes, signature, channel_id) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          groupId,
          author,
          hlc,
          Uint8List.fromList(bytes),
          signature,
          channelId,
        ],
      );
    });
  }

  /// Select a single event by id.
  Future<Map<String, Object?>?> selectEventById(String id) async {
    return await _open(() async {
      final rows = await _executor.runSelect(
        'SELECT id, group_id, author, hlc, bytes, signature, channel_id '
        'FROM events WHERE id = ?',
        [id],
      );
      return rows.isNotEmpty ? rows.first : null;
    });
  }

  /// Get a single event by id, as [EventData].
  Future<EventData?> getEventById(String id) async {
    final row = await selectEventById(id);
    if (row == null) return null;
    return _eventDataFromRow(row);
  }

  static EventData _eventDataFromRow(Map<String, Object?> row) => EventData(
    id: row['id'] as String,
    groupId: row['group_id'] as String,
    author: row['author'] as String,
    hlc: int.parse(row['hlc']!.toString()),
    bytes: Uint8List.fromList(row['bytes'] as List<int>),
    signature: row['signature'] as String,
    channelId: row['channel_id'] as String?,
  );

  /// Select events in hlc range [from, to] (inclusive), ordered by hlc ASC,
  /// then id ASC for deterministic pagination.
  Future<List<Map<String, Object?>>> selectEventsInRange({
    required int hlcFrom,
    required int hlcTo,
    int limit = 1000,
    int offset = 0,
  }) async {
    return await _open(() async {
      return await _executor.runSelect(
        'SELECT id, group_id, author, hlc, bytes, signature, channel_id '
        'FROM events '
        'WHERE hlc BETWEEN ? AND ? '
        'ORDER BY hlc ASC, id ASC '
        'LIMIT ? OFFSET ?',
        [hlcFrom, hlcTo, limit, offset],
      );
    });
  }

  /// Select all events for a group, ordered by hlc ASC, then id ASC.
  Future<List<Map<String, Object?>>> selectEventsForGroup(
    String groupId, {
    int? limit,
    int? offset,
  }) async {
    return await _open(() async {
      final args = <Object?>[groupId];
      var sql =
          'SELECT id, group_id, author, hlc, bytes, signature, channel_id '
          'FROM events WHERE group_id = ? ORDER BY hlc ASC, id ASC';
      if (limit != null) {
        sql += ' LIMIT ?';
        args.add(limit);
        if (offset != null) {
          sql += ' OFFSET ?';
          args.add(offset);
        }
      }
      return await _executor.runSelect(sql, args);
    });
  }

  /// All events for a group, ordered by hlc ASC, as [EventData].
  Future<List<EventData>> groupEvents(
    String groupId, {
    int? limit,
    int? offset,
  }) async {
    final rows = await selectEventsForGroup(
      groupId,
      limit: limit,
      offset: offset,
    );
    return rows.map(_eventDataFromRow).toList();
  }

  /// Select events for a channel (or group-level when [channelId] is null),
  /// ordered by hlc DESC (newest first), then id DESC.
  Future<List<Map<String, Object?>>> selectEventsForChannel(
    String groupId, {
    String? channelId,
    int? limit,
    int? offset,
  }) async {
    return await _open(() async {
      final args = <Object?>[groupId];
      late String sql;
      if (channelId != null) {
        sql =
            'SELECT id, group_id, author, hlc, bytes, signature, channel_id '
            'FROM events WHERE group_id = ? AND channel_id = ? '
            'ORDER BY hlc DESC, id DESC';
        args.add(channelId);
      } else {
        sql =
            'SELECT id, group_id, author, hlc, bytes, signature, channel_id '
            'FROM events WHERE group_id = ? AND channel_id IS NULL '
            'ORDER BY hlc DESC, id DESC';
      }
      if (limit != null) {
        sql += ' LIMIT ?';
        args.add(limit);
        if (offset != null) {
          sql += ' OFFSET ?';
          args.add(offset);
        }
      }
      return await _executor.runSelect(sql, args);
    });
  }

  /// Paginated events for a channel, ordered by hlc DESC (newest first).
  ///
  /// [page] is 1-based. [pageSize] defaults to 50.
  Future<ChannelPage> channelPage({
    required String groupId,
    String? channelId,
    int page = 1,
    int pageSize = 50,
  }) async {
    final offset = (page - 1) * pageSize;
    final rows = await selectEventsForChannel(
      groupId,
      channelId: channelId,
      limit: pageSize + 1,
      offset: offset,
    );
    final hasMore = rows.length > pageSize;
    final eventsList = rows.take(pageSize).map(_eventDataFromRow).toList();
    return ChannelPage(
      events: eventsList,
      page: page,
      pageSize: pageSize,
      hasMore: hasMore,
    );
  }

  /// Count events for a group (or channel within group).
  Future<int> countEvents(String groupId, {String? channelId}) async {
    return await _open(() async {
      final args = <Object?>[groupId];
      late String sql;
      if (channelId != null) {
        sql = 'SELECT COUNT(*) as c FROM events WHERE group_id = ? AND channel_id = ?';
        args.add(channelId);
      } else {
        sql = 'SELECT COUNT(*) as c FROM events WHERE group_id = ? AND channel_id IS NULL';
      }
      final rows = await _executor.runSelect(sql, args);
      return int.parse(rows.first['c']!.toString());
    });
  }

  /// История с события [cursor] включительно.
  ///
  /// Неизвестный или пустой cursor означает начало истории. Порядок —
  /// `hlc ASC, id ASC`.
  Future<List<EventData>> eventsFromCursor(String cursor) async {
    return await _open(() async {
      const columns =
          'id, group_id, author, hlc, bytes, signature, channel_id';
      List<Map<String, Object?>> rows;
      if (cursor.isEmpty) {
        rows = await _executor.runSelect(
          'SELECT $columns FROM events ORDER BY hlc ASC, id ASC',
          const [],
        );
      } else {
        final cursorRows = await _executor.runSelect(
          'SELECT hlc FROM events WHERE id = ?',
          [cursor],
        );
        if (cursorRows.isEmpty) {
          rows = await _executor.runSelect(
            'SELECT $columns FROM events ORDER BY hlc ASC, id ASC',
            const [],
          );
        } else {
          final cursorHlc = cursorRows.first['hlc'];
          rows = await _executor.runSelect(
            'SELECT $columns FROM events '
            'WHERE hlc > ? OR (hlc = ? AND id >= ?) '
            'ORDER BY hlc ASC, id ASC',
            [cursorHlc, cursorHlc, cursor],
          );
        }
      }
      return rows.map(_eventDataFromRow).toList();
    });
  }

  /// Select event ids in hlc range [from, to] (inclusive), ordered by hlc ASC.
  /// Lightweight — only returns ids, not payloads.
  Future<List<String>> selectEventIdsInRange({
    required int hlcFrom,
    required int hlcTo,
    int limit = maxRangeEvents,
    int offset = 0,
  }) async {
    return await _open(() async {
      final rows = await _executor.runSelect(
        'SELECT id FROM events '
        'WHERE hlc BETWEEN ? AND ? '
        'ORDER BY hlc ASC, id ASC '
        'LIMIT ? OFFSET ?',
        [hlcFrom, hlcTo, limit, offset],
      );
      return rows.map((r) => r['id'] as String).toList();
    });
  }

  /// Summary of events in the hlc range [from, to] (inclusive).
  ///
  /// SHA-256 считается по `ids.join('|')` в UTF-8. Если событий больше
  /// [limit], возвращается [RangeTooLarge], а не усечённый digest.
  Future<Result<RangeSummary, RangeSummaryError>> rangeSummary(
    int hlcFrom,
    int hlcTo, {
    int limit = maxRangeEvents,
  }) async {
    final ids = await selectEventIdsInRange(
      hlcFrom: hlcFrom,
      hlcTo: hlcTo,
      limit: limit + 1,
    );
    if (ids.length > limit) {
      return Err(RangeTooLarge(limit));
    }

    final digest = sha256.convert(utf8.encode(ids.join('|')));
    return Ok(
      RangeSummary(
        count: ids.length,
        rangeHash: Uint8List.fromList(digest.bytes),
        hlcFrom: hlcFrom,
        hlcTo: hlcTo,
      ),
    );
  }

  /// Batch of events in hlc range [from, to], ordered by hlc ASC.
  Future<List<EventData>> batchEvents({
    required int hlcFrom,
    required int hlcTo,
    int limit = 1000,
    int offset = 0,
  }) async {
    final rows = await selectEventsInRange(
      hlcFrom: hlcFrom,
      hlcTo: hlcTo,
      limit: limit,
      offset: offset,
    );
    return rows.map(_eventDataFromRow).toList();
  }

  // -------------------------------------------------------------------------
  // Groups
  // -------------------------------------------------------------------------

  Future<void> upsertGroup({
    required String id,
    required String name,
    required String ownerId,
    required int createdAt,
    required int updatedAt,
  }) async {
    await _open(() async {
      await _executor.runInsert(
        'INSERT OR REPLACE INTO groups (id, name, owner_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [id, name, ownerId, createdAt, updatedAt],
      );
    });
  }

  Future<List<Map<String, Object?>>> selectAllGroups() async {
    return await _open(() async {
      return await _executor.runSelect(
        'SELECT id, name, owner_id, created_at, updated_at FROM groups',
        [],
      );
    });
  }

  // -------------------------------------------------------------------------
  // Members
  // -------------------------------------------------------------------------

  Future<void> addMember({
    required String groupId,
    required String userId,
    required int joinedAt,
  }) async {
    await _open(() async {
      await _executor.runInsert(
        'INSERT OR IGNORE INTO members (group_id, user_id, joined_at) VALUES (?, ?, ?)',
        [groupId, userId, joinedAt],
      );
    });
  }

  Future<void> removeMember(String groupId, String userId) async {
    await _open(() async {
      await _executor.runDelete(
        'DELETE FROM members WHERE group_id = ? AND user_id = ?',
        [groupId, userId],
      );
    });
  }

  Future<List<Map<String, Object?>>> selectMembersForGroup(
    String groupId,
  ) async {
    return await _open(() async {
      return await _executor.runSelect(
        'SELECT user_id, joined_at FROM members WHERE group_id = ?',
        [groupId],
      );
    });
  }

  // -------------------------------------------------------------------------
  // Channels
  // -------------------------------------------------------------------------

  Future<void> upsertChannel({
    required String id,
    required String groupId,
    required String name,
    required String type,
    required String createdBy,
    required int createdAt,
  }) async {
    await _open(() async {
      await _executor.runInsert(
        'INSERT OR REPLACE INTO channels (id, group_id, name, type, created_by, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [id, groupId, name, type, createdBy, createdAt],
      );
    });
  }

  Future<List<Map<String, Object?>>> selectChannelsForGroup(
    String groupId,
  ) async {
    return await _open(() async {
      return await _executor.runSelect(
        'SELECT id, group_id, name, type, created_by, created_at FROM channels WHERE group_id = ?',
        [groupId],
      );
    });
  }

  // -------------------------------------------------------------------------
  // Peers
  // -------------------------------------------------------------------------

  Future<void> upsertPeer({
    required String peerId,
    required int lastSeen,
    String? address,
  }) async {
    await _open(() async {
      await _executor.runInsert(
        'INSERT OR REPLACE INTO peers (peer_id, last_seen, address) VALUES (?, ?, ?)',
        [peerId, lastSeen, address],
      );
    });
  }

  // -------------------------------------------------------------------------
  // Group settings
  // -------------------------------------------------------------------------

  Future<void> upsertGroupSetting({
    required String id,
    required String groupId,
    required String key,
    required String value,
    required int updatedAt,
  }) async {
    await _open(() async {
      await _executor.runInsert(
        'INSERT OR REPLACE INTO group_settings (id, group_id, key, value, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [id, groupId, key, value, updatedAt],
      );
    });
  }

  Future<List<Map<String, Object?>>> selectGroupSettingsForGroup(
    String groupId,
  ) async {
    return await _open(() async {
      return await _executor.runSelect(
        'SELECT id, group_id, key, value, updated_at FROM group_settings WHERE group_id = ?',
        [groupId],
      );
    });
  }

  // -------------------------------------------------------------------------
  // Blobs meta
  // -------------------------------------------------------------------------

  Future<void> insertBlobMeta({
    required String id,
    required String groupId,
    String? channelId,
    String? messageId,
    required String filename,
    required String mimeType,
    required int size,
    required int createdAt,
    int? expiresAt,
  }) async {
    await _open(() async {
      await _executor.runInsert(
        'INSERT OR REPLACE INTO blobs_meta '
        '(id, group_id, channel_id, message_id, filename, mime_type, size, created_at, expires_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          groupId,
          channelId,
          messageId,
          filename,
          mimeType,
          size,
          createdAt,
          expiresAt,
        ],
      );
    });
  }

  /// Delete a single blob metadata row by id.
  Future<int> deleteBlobMeta(String id) async {
    return await _open(() async {
      return await _executor.runDelete(
        'DELETE FROM blobs_meta WHERE id = ?',
        [id],
      );
    });
  }

  /// Delete blob metadata rows with expires_at < [beforeTimestamp].
  /// Returns the number of deleted rows.
  Future<int> expireBlobs(int beforeTimestamp) async {
    return await _open(() async {
      return await _executor.runDelete(
        'DELETE FROM blobs_meta WHERE expires_at IS NOT NULL AND expires_at < ?',
        [beforeTimestamp],
      );
    });
  }

  /// Select expired blob metadata (for the caller to delete actual files).
  Future<List<Map<String, Object?>>> selectExpiredBlobs(
    int beforeTimestamp,
  ) async {
    return await _open(() async {
      return await _executor.runSelect(
        'SELECT id, group_id, channel_id, message_id, filename, mime_type, size, created_at, expires_at '
        'FROM blobs_meta WHERE expires_at IS NOT NULL AND expires_at < ?',
        [beforeTimestamp],
      );
    });
  }

  // -------------------------------------------------------------------------
  // Sync state
  // -------------------------------------------------------------------------

  Future<void> setSyncState(String key, List<int> value) async {
    await _open(() async {
      await _executor.runInsert(
        'INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)',
        [key, Uint8List.fromList(value)],
      );
    });
  }

  Future<Uint8List?> getSyncState(String key) async {
    return await _open(() async {
      final rows = await _executor.runSelect(
        'SELECT value FROM sync_state WHERE key = ?',
        [key],
      );
      if (rows.isEmpty) return null;
      final raw = rows.first['value'];
      if (raw is Uint8List) return raw;
      if (raw is List<int>) return Uint8List.fromList(raw);
      return null;
    });
  }
}
