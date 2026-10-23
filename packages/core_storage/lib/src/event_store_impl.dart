import 'dart:async';

import 'package:core_domain/core_domain.dart';

import 'database/app_database.dart';

/// Drift-backed implementation of EventStore.
///
/// Inserts are idempotent: caller-provided event id is the primary key, so
/// re-inserting the same event is a no-op via INSERT OR IGNORE.
/// Watches replay history and then expose the append-only log as broadcast
/// streams.
class DriftEventStore implements EventStore {
  /// Максимальный размер payload события (1 МБ).
  static const int _maxPayloadSize = 1024 * 1024;

  /// Ожидаемая длина hex-строки автора: 32 байта Ed25519 ключа = 64 hex-символа.
  static const int _authorHexLength = 64;

  /// Допустимый id: ASCII-идентификатор до 128 символов.
  ///
  /// Хранилище не вычисляет content hash; id задаёт вызывающий слой.
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

  final AppDatabase _db;
  final StreamController<EventRecord> _writeController =
      StreamController<EventRecord>.broadcast();

  DriftEventStore(this._db);

  /// Idempotent insert. Duplicate event id → no-op, no error.
  ///
  /// Validates the record before writing: invalid author, id, or payload
  /// returns a Result error with a typed [EventStoreWriteError] and nothing
  /// is written to the database.
  ///
  /// [EventRecord.author] is supplied by the caller (layer 7 pipeline after
  /// signature verification). The storage does not extract the author from
  /// the opaque payload.
  @override
  Future<Result<InsertOutcome, EventStoreWriteError>> write(
      EventRecord record) async {
    final validationError = _validate(record);
    if (validationError != null) {
      return Err(validationError);
    }

    try {
      final affected = await _db.insertEvent(
        id: record.id,
        groupId: record.groupId.value,
        author: record.author,
        hlc: record.timestamp,
        bytes: record.payload,
        signature: record.signature,
        channelId: record.channelId?.value,
      );

      final inserted = affected == 1;
      final duplicate = affected == 0;

      if (inserted) {
        _writeController.add(record);
      }

      return Ok(InsertOutcome(inserted: inserted, duplicate: duplicate));
    } catch (_) {
      return const Err(StorageWriteError());
    }
  }

  /// Проверка формы записи перед возможной вставкой в БД.
  /// Возвращает null если запись валидна, иначе типизированную ошибку.
  EventStoreWriteError? _validate(EventRecord record) {
    if (!_idPattern.hasMatch(record.id)) {
      return const InvalidId();
    }

    final author = record.author;
    if (author.isEmpty) {
      return const InvalidAuthor();
    }
    // Автор — 32-байтный Ed25519 публичный ключ в hex: ровно 64 hex-символа.
    if (author.length != _authorHexLength) {
      return const InvalidAuthor();
    }
    try {
      final authorBytes = _hexToBytes(author);
      if (authorBytes.length != 32) {
        return const InvalidAuthor();
      }
    } on FormatException {
      return const InvalidAuthor();
    }

    if (record.payload.isEmpty) {
      return const InvalidPayload();
    }
    if (record.payload.length > _maxPayloadSize) {
      return const PayloadTooLarge();
    }

    return null;
  }

  /// Декодирует hex-строку в список байт. Бросает [FormatException] при
  /// некорректном входе.
  static List<int> _hexToBytes(String hex) {
    if (hex.isEmpty || hex.length % 2 != 0) {
      throw const FormatException('Invalid hex string');
    }
    return List<int>.generate(hex.length ~/ 2, (i) {
      return int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    });
  }

  /// История с [cursor] включительно, затем live-записи.
  @override
  Stream<EventRecord> watchFrom(String cursor) {
    return _watchWithReplay(
      loadHistory: () async {
        final events = await _db.eventsFromCursor(cursor);
        return events.map((event) => event.toEventRecord()).toList();
      },
      matches: (_) => true,
    );
  }

  /// История группы (hlc ASC), затем live-записи этой группы.
  @override
  Stream<EventRecord> watchGroup(GroupId groupId) {
    return _watchWithReplay(
      loadHistory: () async {
        final events = await _db.groupEvents(groupId.value);
        return events.map((event) => event.toEventRecord()).toList();
      },
      matches: (record) => record.groupId == groupId,
    );
  }

  /// Подписка на live-поток до чтения истории, чтобы не потерять запись
  /// между запросом истории и подпиской. Дубли по id подавляются.
  Stream<EventRecord> _watchWithReplay({
    required Future<List<EventRecord>> Function() loadHistory,
    required bool Function(EventRecord) matches,
  }) {
    late final StreamController<EventRecord> controller;
    StreamSubscription<EventRecord>? liveSubscription;
    final buffered = <EventRecord>[];
    final emittedIds = <String>{};
    var replaying = true;
    var cancelled = false;

    Future<void> start() async {
      liveSubscription = _writeController.stream.where(matches).listen(
        (event) {
          if (replaying) {
            buffered.add(event);
          } else if (emittedIds.add(event.id)) {
            controller.add(event);
          }
        },
        onError: controller.addError,
        onDone: () async {
          if (!cancelled && !controller.isClosed) {
            await controller.close();
          }
        },
      );

      try {
        final history = await loadHistory();
        if (cancelled) return;
        for (final event in history) {
          if (emittedIds.add(event.id)) {
            controller.add(event);
          }
        }
        replaying = false;
        for (final event in buffered) {
          if (emittedIds.add(event.id)) {
            controller.add(event);
          }
        }
        buffered.clear();
      } catch (error, stackTrace) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(error, stackTrace);
          await controller.close();
        }
      }
    }

    controller = StreamController<EventRecord>(
      onListen: () => unawaited(start()),
      onCancel: () async {
        cancelled = true;
        await liveSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// Looks up a single event by its id.
  Future<EventRecord?> getEvent(String id) async {
    final data = await _db.getEventById(id);
    return data?.toEventRecord();
  }

  @override
  Future<void> close() async {
    await _writeController.close();
    await _db.close();
  }
}
