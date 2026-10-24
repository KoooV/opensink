import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:core_domain/core_domain.dart';
import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'frame.dart';
import 'hlc.dart';
import 'ingest_pipeline.dart';
import 'link.dart';
import 'projection.dart';
import 'sync_event.dart';

/// Реализация SyncEngine: HLC, приём, anti-entropy, gossip и приоритетная
/// загрузка каналов.
class SyncEngineImpl implements SyncEngine {
  SyncEngineImpl({
    required this.store,
    required this.signer,
    required this.localAuthor,
    HlcClock? clock,
    int Function()? nowMs,
    this.priorityWindow = 50,
    this.maxBatchSize = 64,
    this.maxGossipHops = 4,
    this.maxSeenEvents = 20000,
    this.maxPendingEvents = 2048,
    this.maxOutboundQueue = 2048,
    Duration? antiEntropyInterval,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _clock = clock ?? HlcClock(nowMs: nowMs) {
    _pipeline = SyncIngestPipeline(
      store: store,
      signer: signer,
      membershipCheck: _membershipStatus,
      nowMs: _nowMs,
    );
    if (antiEntropyInterval != null) {
      _antiEntropyTimer = Timer.periodic(
        antiEntropyInterval,
        (_) => unawaited(runAntiEntropy()),
      );
    }
  }

  final SyncEventStore store;
  final Signer signer;
  final UserId localAuthor;
  final int priorityWindow;
  final int maxBatchSize;
  final int maxGossipHops;
  final int maxSeenEvents;
  final int maxPendingEvents;
  final int maxOutboundQueue;

  final int Function() _nowMs;
  final HlcClock _clock;
  late final SyncIngestPipeline _pipeline;
  final SyncEventCodec _eventCodec = const SyncEventCodec();
  final SyncFrameCodec _frameCodec = const SyncFrameCodec();
  final MembershipEvaluator _membershipEvaluator = const MembershipEvaluator();

  final Map<GroupId, SplayTreeSet<SyncEvent>> _events = {};
  final Map<GroupId, Map<String, SyncEvent>> _lastAuthorEvent = {};
  final Set<GroupId> _groupIds = {};
  final Set<GroupId> _loadedGroups = {};
  final Map<GroupId, Future<void>> _loadFutures = {};
  final Map<String, _LinkSession> _links = {};
  final LinkedHashMap<String, bool> _seen = LinkedHashMap<String, bool>();
  final LinkedHashMap<String, SyncEvent> _pending =
      LinkedHashMap<String, SyncEvent>();
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final Set<GroupId> _retryingPending = {};

  Timer? _antiEntropyTimer;
  bool _closed = false;

  @override
  Stream<void> get changes => _changes.stream;

  Hlc get lastHlc => _clock.last;

  bool get isIdle => _links.values.every((session) => session.isIdle);

  int get neighborCount => _links.length;

  /// Регистрирует группу и подгружает её историю из хранилища.
  Future<void> registerGroup(GroupId groupId) async {
    _groupIds.add(groupId);
    await _ensureGroup(groupId);
  }

  /// Подключает соседа. При появлении линка сразу отправляются приоритетные
  /// запросы последних сообщений каналов и сводки для anti-entropy.
  Future<void> attach(SyncLink link) async {
    if (_closed) return;
    if (_links.containsKey(link.peerId)) return;
    final session = _LinkSession(engine: this, link: link);
    _links[link.peerId] = session;
    await session.start();
  }

  Future<void> detach(String peerId) async {
    final session = _links.remove(peerId);
    await session?.close();
  }

  Future<void> _onLinkClosed(_LinkSession session) async {
    if (identical(_links[session.peerId], session)) {
      _links.remove(session.peerId);
    }
    await session.close();
  }

  Future<void> _onLinkReady(_LinkSession session) async {
    for (final groupId in _groupIds.toList()) {
      await _ensureGroup(groupId);
      for (final channelId in _channelsOf(groupId)) {
        session.enqueue(
          WindowRequestFrame(
            requestId: session.nextRequestId(),
            groupId: groupId,
            channelId: channelId,
            limit: priorityWindow,
          ),
          high: true,
        );
      }
      session.enqueue(
        SummaryFrame(groupId: groupId, ranges: _buildSummary(groupId)),
      );
    }
  }

  /// Периодический/ручной обмен сводками со всеми соседями.
  Future<void> runAntiEntropy() async {
    if (_closed) return;
    for (final groupId in _groupIds.toList()) {
      await _ensureGroup(groupId);
      final summary = SummaryFrame(
        groupId: groupId,
        ranges: _buildSummary(groupId),
      );
      for (final session in _links.values.toList()) {
        session.enqueue(summary);
      }
    }
  }

  @override
  Future<void> sync() => runAntiEntropy();

  /// Запрашивает у соседей последние [limit] событий канала.
  Future<void> loadChannelWindow(
    GroupId groupId,
    ChannelId channelId, {
    int? limit,
  }) async {
    await _ensureGroup(groupId);
    final n = limit ?? priorityWindow;
    for (final session in _links.values.toList()) {
      session.enqueue(
        WindowRequestFrame(
          requestId: session.nextRequestId(),
          groupId: groupId,
          channelId: channelId,
          limit: n,
        ),
        high: true,
      );
    }
  }

  /// Явный запрос истории группы (UI: прокрутка вверх / открытие канала).
  ///
  /// Автоматический anti-entropy догружает только самый свежий диапазон.
  /// Вся остальная история приходит страницами после этого вызова.
  /// Если задан [channelId], запрашиваются только события этого канала,
  /// включая ответы на последующие страницы.
  Future<void> requestHistory(
    GroupId groupId, {
    ChannelId? channelId,
    int fromHlc = 0,
    int? toHlc,
  }) async {
    await _ensureGroup(groupId);
    final upper = toHlc ?? maxSyncHlcPhysical;
    final channelKey = channelId?.value ?? '*';
    for (final session in _links.values.toList()) {
      final requestId = session.nextRequestId();
      session.registerRangeRequest(
        requestId,
        '$groupId:$channelKey:$fromHlc:$upper',
        groupId,
        fromHlc,
        upper,
        channelId: channelId,
      );
      session.enqueue(
        RangeRequestFrame(
          requestId: requestId,
          groupId: groupId,
          fromHlc: fromHlc,
          toHlc: upper,
          limit: maxBatchSize,
          channelId: channelId,
        ),
      );
    }
  }

  /// Локальное окно последних сообщений канала.
  Future<List<SyncEvent>> channelWindow(
    GroupId groupId,
    ChannelId channelId, {
    int? limit,
  }) async {
    await _ensureGroup(groupId);
    final n = limit ?? priorityWindow;
    final all = (_events[groupId] ?? SplayTreeSet<SyncEvent>(_compare))
        .where(
          (event) =>
              event.channelId == channelId &&
              event.kind == SyncEventKind.messageCreated,
        )
        .toList();
    if (all.length <= n) return all;
    return all.sublist(all.length - n);
  }

  Future<List<SyncEvent>> allEvents(GroupId groupId) async {
    await _ensureGroup(groupId);
    return (_events[groupId] ?? SplayTreeSet<SyncEvent>(_compare)).toList();
  }

  /// Чистая проекция состояния группы.
  Future<GroupProjection> projection(GroupId groupId) async {
    await _ensureGroup(groupId);
    return GroupProjection.fromEvents(_events[groupId] ?? const <SyncEvent>[]);
  }

  Future<SyncEvent?> eventById(String id) async {
    final pending = _pending[id];
    if (pending != null) return pending;
    for (final events in _events.values) {
      final found = events.firstWhereOrNull((event) => event.id.value == id);
      if (found != null) return found;
    }
    final record = await store.eventById(id);
    if (record == null) return null;
    final decoded = _eventCodec.fromRecord(record);
    return decoded.isOk ? decoded.unwrap() : null;
  }

  Future<Result<SyncEvent, SyncError>> createGroup(
    GroupId groupId, {
    Uint8List? payload,
  }) {
    return createEvent(
      groupId: groupId,
      kind: SyncEventKind.groupCreated,
      payload: payload,
    );
  }

  Future<Result<SyncEvent, SyncError>> addMember(
    GroupId groupId,
    UserId userId,
  ) {
    return createEvent(
      groupId: groupId,
      kind: SyncEventKind.memberAdded,
      targetId: userId.value,
    );
  }

  Future<Result<SyncEvent, SyncError>> removeMember(
    GroupId groupId,
    UserId userId,
  ) {
    return createEvent(
      groupId: groupId,
      kind: SyncEventKind.memberRemoved,
      targetId: userId.value,
    );
  }

  Future<Result<SyncEvent, SyncError>> createChannel(
    GroupId groupId,
    ChannelId channelId, {
    String? name,
  }) {
    return createEvent(
      groupId: groupId,
      kind: SyncEventKind.channelCreated,
      channelId: channelId,
      targetId: channelId.value,
      payload: name == null ? null : Uint8List.fromList(utf8.encode(name)),
    );
  }

  Future<Result<SyncEvent, SyncError>> renameGroup(
    GroupId groupId,
    String name,
  ) {
    return createEvent(
      groupId: groupId,
      kind: SyncEventKind.groupRenamed,
      payload: Uint8List.fromList(utf8.encode(name)),
    );
  }

  Future<Result<SyncEvent, SyncError>> postMessage(
    GroupId groupId,
    ChannelId channelId,
    String text,
  ) {
    return createEvent(
      groupId: groupId,
      channelId: channelId,
      kind: SyncEventKind.messageCreated,
      payload: Uint8List.fromList(utf8.encode(text)),
    );
  }

  Future<Result<SyncEvent, SyncError>> editMessage(
    GroupId groupId,
    ChannelId channelId,
    EventId target,
    String newText,
  ) {
    return createEvent(
      groupId: groupId,
      channelId: channelId,
      kind: SyncEventKind.messageEdited,
      targetId: target.value,
      payload: Uint8List.fromList(utf8.encode(newText)),
    );
  }

  Future<Result<SyncEvent, SyncError>> deleteMessage(
    GroupId groupId,
    ChannelId channelId,
    EventId target,
  ) {
    return createEvent(
      groupId: groupId,
      channelId: channelId,
      kind: SyncEventKind.messageDeleted,
      targetId: target.value,
    );
  }

  /// Создаёт, подписывает и локально применяет событие.
  Future<Result<SyncEvent, SyncError>> createEvent({
    required GroupId groupId,
    required SyncEventKind kind,
    ChannelId? channelId,
    String? targetId,
    Uint8List? payload,
  }) async {
    await registerGroup(groupId);
    final hlc = _clock.tick();
    final previous = _lastAuthorEvent[groupId]?[localAuthor.value];

    final draft = SyncEvent(
      id: const EventId(''),
      groupId: groupId,
      channelId: channelId,
      authorId: localAuthor,
      hlc: hlc,
      kind: kind,
      targetId: targetId,
      prevId: previous?.id,
      payload: payload,
    );
    final id = draft.computeId();
    final unsigned = draft.copyWith(id: EventId(id));
    final signature = await signer.sign(unsigned.signedBytes());
    final event = unsigned.copyWith(signature: signature);

    final ingested = await _ingest(event);
    if (ingested.isErr) {
      return Err(LocalEventRejected(ingested.unwrapErr()));
    }
    final outcome = ingested.unwrap().outcome;
    if (outcome != IngestOutcome.inserted) {
      return Err(
        LocalEventRejected(
          outcome == IngestOutcome.pending
              ? NotAMember(localAuthor.value, groupId.value)
              : const MalformedEvent('local event is duplicate'),
        ),
      );
    }

    await _broadcastGossip(<SyncEvent>[event]);
    return Ok(event);
  }

  /// Принимает готовое подписанное событие из внешнего транспорта.
  ///
  /// Использует тот же конвейер, что и сетевой приём: размер → id →
  /// подпись → членство → дедупликация → запись.
  Future<Result<IngestResult, SyncError>> ingest(SyncEvent event) =>
      _ingest(event);

  Future<Result<IngestResult, SyncError>> _ingest(
    SyncEvent event, {
    String? sourcePeer,
  }) async {
    if (_closed) {
      return const Err(StorageWriteFailure('engine is closed'));
    }
    final id = event.id.value;
    if (_seen.containsKey(id)) {
      return const Ok(IngestResult(IngestOutcome.duplicate));
    }
    if (_pending.containsKey(id)) {
      return const Ok(IngestResult(IngestOutcome.pending));
    }

    await _ensureGroup(event.groupId);
    final result = await _pipeline.ingest(event);
    if (result.isErr) return result;

    final outcome = result.unwrap().outcome;
    switch (outcome) {
      case IngestOutcome.inserted:
        _seen[id] = true;
        _trimSeen();
        _addToIndex(event);
        _clock.observe(event.hlc);
        _changes.add(null);
        await _retryPending(event.groupId);
      case IngestOutcome.duplicate:
        _seen[id] = true;
        _trimSeen();
        _addToIndex(event);
        _clock.observe(event.hlc);
      case IngestOutcome.pending:
        await _persistPending(event);
        _pending[id] = event;
        await _trimPending();
    }
    return Ok(IngestResult(outcome));
  }

  Future<void> _retryPending(GroupId groupId) async {
    if (_retryingPending.contains(groupId)) return;
    if (!_pending.values.any((event) => event.groupId == groupId)) return;
    _retryingPending.add(groupId);
    final accepted = <SyncEvent>[];
    try {
      for (var pass = 0; pass < 8; pass++) {
        var progress = false;
        final candidates = _pending.values
            .where((event) => event.groupId == groupId)
            .toList();
        for (final event in candidates) {
          final status = _membershipStatus(event);
          if (status == MembershipStatus.notMember) {
            _pending.remove(event.id.value);
            await _deletePending(event.id.value);
            progress = true;
            continue;
          }
          if (status != MembershipStatus.member) continue;
          final result = await _pipeline.ingest(event);
          if (result.isErr) continue;
          switch (result.unwrap().outcome) {
            case IngestOutcome.inserted:
              _pending.remove(event.id.value);
              await _deletePending(event.id.value);
              _seen[event.id.value] = true;
              _trimSeen();
              _addToIndex(event);
              _clock.observe(event.hlc);
              _changes.add(null);
              accepted.add(event);
              progress = true;
            case IngestOutcome.duplicate:
              _pending.remove(event.id.value);
              await _deletePending(event.id.value);
              _seen[event.id.value] = true;
              _trimSeen();
              _addToIndex(event);
            case IngestOutcome.pending:
              _pending[event.id.value] = event;
          }
        }
        if (!progress) break;
      }
    } finally {
      _retryingPending.remove(groupId);
    }
    if (accepted.isNotEmpty) {
      await _broadcastGossip(accepted);
    }
  }

  MembershipStatus _membershipStatus(SyncEvent event) {
    final timeline = _events[event.groupId] ?? const <SyncEvent>{};
    return _membershipEvaluator.evaluate(event, timeline);
  }

  Future<void> _ensureGroup(GroupId groupId) {
    if (_loadedGroups.contains(groupId)) return Future<void>.value();
    final inFlight = _loadFutures[groupId];
    if (inFlight != null) return inFlight;
    final future = _loadGroup(groupId);
    _loadFutures[groupId] = future;
    return future.whenComplete(() {
      _loadFutures.remove(groupId);
    });
  }

  Future<void> _loadGroup(GroupId groupId) async {
    final records = await store.groupEvents(groupId);
    for (final record in records) {
      final decoded = _eventCodec.fromRecord(record);
      if (decoded.isOk) _addToIndex(decoded.unwrap());
    }
    final pending = await store.pendingEvents(groupId, limit: maxPendingEvents);
    for (final record in pending) {
      final decoded = _eventCodec.fromRecord(record);
      if (decoded.isOk) _pending[record.id] = decoded.unwrap();
    }
    _loadedGroups.add(groupId);
    _groupIds.add(groupId);
    await _retryPending(groupId);
  }

  void _addToIndex(SyncEvent event) {
    final set = _events.putIfAbsent(
      event.groupId,
      () => SplayTreeSet<SyncEvent>(_compare),
    );
    if (!set.add(event)) return;
    final byAuthor = _lastAuthorEvent.putIfAbsent(
      event.groupId,
      () => <String, SyncEvent>{},
    );
    final previous = byAuthor[event.authorId.value];
    if (previous == null || previous.compareTo(event) < 0) {
      byAuthor[event.authorId.value] = event;
    }
  }

  List<RangeDigest> _buildSummary(GroupId groupId) {
    final set = _events[groupId];
    if (set == null || set.isEmpty) return const <RangeDigest>[];
    const width = syncSummaryBucketMs;
    final buckets = SplayTreeMap<int, List<SyncEvent>>();
    for (final event in set) {
      final bucket = event.hlc.physicalMs ~/ width;
      buckets.putIfAbsent(bucket, () => <SyncEvent>[]).add(event);
    }
    final ranges = <RangeDigest>[];
    for (final entry in buckets.entries) {
      final ids = entry.value.map((event) => event.id.value).toList();
      ranges.add(
        RangeDigest(
          fromHlc: entry.key * width,
          toHlc: (entry.key + 1) * width - 1,
          count: ids.length,
          hashHex: sha256.convert(utf8.encode(ids.join('|'))).toString(),
        ),
      );
    }
    return ranges;
  }

  RangeDigest _localDigest(GroupId groupId, int fromHlc, int toHlc) {
    final set = _events[groupId];
    if (set == null) {
      return RangeDigest(
        fromHlc: fromHlc,
        toHlc: toHlc,
        count: 0,
        hashHex: sha256.convert(const <int>[]).toString(),
      );
    }
    final ids = <String>[];
    for (final event in set) {
      if (event.hlc.physicalMs < fromHlc) continue;
      if (event.hlc.physicalMs > toHlc) break;
      ids.add(event.id.value);
    }
    return RangeDigest(
      fromHlc: fromHlc,
      toHlc: toHlc,
      count: ids.length,
      hashHex: sha256.convert(utf8.encode(ids.join('|'))).toString(),
    );
  }

  List<ChannelId> _channelsOf(GroupId groupId) {
    final channels = <String>{};
    final set = _events[groupId];
    if (set != null) {
      for (final event in set) {
        final channel = event.channelId?.value;
        if (channel != null) channels.add(channel);
        if ((event.kind == SyncEventKind.channelCreated ||
                event.kind == SyncEventKind.channelDeleted) &&
            event.targetId != null) {
          channels.add(event.targetId!);
        }
      }
    }
    final result = channels.map(ChannelId.new).toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return result;
  }

  Future<void> _onSummary(_LinkSession session, SummaryFrame frame) async {
    await _ensureGroup(frame.groupId);
    RangeDigest? newestMismatch;
    for (final digest in frame.ranges) {
      final local = _localDigest(frame.groupId, digest.fromHlc, digest.toHlc);
      if (local.count == digest.count && local.hashHex == digest.hashHex) {
        continue;
      }
      if (newestMismatch == null || digest.toHlc > newestMismatch.toHlc) {
        newestMismatch = digest;
      }
    }
    // Автоматически догружаем только самый свежий расходящийся диапазон.
    // Остальная история запрашивается явно через requestHistory (UI).
    if (newestMismatch == null) return;
    final digest = newestMismatch;
    final key = '${frame.groupId.value}:${digest.fromHlc}:${digest.toHlc}';
    final requestId = session.nextRequestId();
    session.registerRangeRequest(
      requestId,
      key,
      frame.groupId,
      digest.fromHlc,
      digest.toHlc,
    );
    session.enqueue(
      RangeRequestFrame(
        requestId: requestId,
        groupId: frame.groupId,
        fromHlc: digest.fromHlc,
        toHlc: digest.toHlc,
        limit: maxBatchSize,
      ),
    );
  }

  Future<void> _onRangeRequest(
    _LinkSession session,
    RangeRequestFrame frame,
  ) async {
    final limit = math.min(math.max(1, frame.limit), maxEventsPerFrame);
    final records = await store.eventsInRange(
      frame.groupId,
      hlcFrom: frame.fromHlc,
      hlcTo: frame.toHlc,
      limit: limit,
      afterHlc: frame.afterHlc,
      afterId: frame.afterId,
      channelId: frame.channelId,
    );
    final events = <SyncEvent>[];
    for (final record in records) {
      final decoded = _eventCodec.fromRecord(record);
      if (decoded.isOk) events.add(decoded.unwrap());
    }
    final cursor = events.isEmpty ? null : events.last;
    session.enqueue(
      EventsFrame(
        requestId: frame.requestId,
        groupId: frame.groupId,
        events: events,
        more: events.length == limit && cursor != null,
        cursorHlc: cursor?.hlc.physicalMs,
        cursorId: cursor?.id.value,
      ),
    );
  }

  Future<void> _onWindowRequest(
    _LinkSession session,
    WindowRequestFrame frame,
  ) async {
    final limit = math.min(math.max(1, frame.limit), maxEventsPerFrame);
    final records = await store.latestChannelEvents(
      frame.groupId,
      frame.channelId,
      limit: limit,
    );
    final events = <SyncEvent>[];
    for (final record in records) {
      final decoded = _eventCodec.fromRecord(record);
      if (decoded.isOk) events.add(decoded.unwrap());
    }
    events.sort((a, b) => a.compareTo(b));
    session.enqueue(
      EventsFrame(
        requestId: frame.requestId,
        groupId: frame.groupId,
        events: events,
      ),
      high: true,
    );
  }

  Future<void> _onEvents(_LinkSession session, EventsFrame frame) async {
    final inserted = <SyncEvent>[];
    for (final event in frame.events) {
      final result = await _ingest(event, sourcePeer: session.peerId);
      if (result.isOk && result.unwrap().isInserted) {
        inserted.add(event);
      }
    }
    if (inserted.isNotEmpty) {
      await _broadcastGossip(inserted, excludePeer: session.peerId, hops: 1);
    }

    final state = session.rangeRequest(frame.requestId);
    if (!frame.more || state == null) {
      session.completeRangeRequest(frame.requestId);
      return;
    }
    if (frame.events.isEmpty || frame.cursorHlc == null) {
      session.completeRangeRequest(frame.requestId);
      return;
    }

    session.enqueue(
      RangeRequestFrame(
        requestId: frame.requestId,
        groupId: state.groupId,
        fromHlc: state.fromHlc,
        toHlc: state.toHlc,
        afterHlc: frame.cursorHlc,
        afterId: frame.cursorId,
        limit: maxBatchSize,
        channelId: state.channelId,
      ),
    );
  }

  Future<void> _onGossip(_LinkSession session, GossipFrame frame) async {
    final inserted = <SyncEvent>[];
    for (final event in frame.events) {
      final result = await _ingest(event, sourcePeer: session.peerId);
      if (result.isOk && result.unwrap().isInserted) {
        inserted.add(event);
      }
    }
    if (inserted.isEmpty) return;
    if (frame.hops >= maxGossipHops) return;
    await _broadcastGossip(
      inserted,
      excludePeer: session.peerId,
      hops: frame.hops + 1,
    );
  }

  Future<void> _broadcastGossip(
    List<SyncEvent> events, {
    String? excludePeer,
    int hops = 0,
  }) async {
    if (events.isEmpty || _closed) return;
    for (final session in _links.values.toList()) {
      if (session.peerId == excludePeer) continue;
      final fresh = <SyncEvent>[];
      for (final event in events) {
        if (session.shouldGossip(event.id.value)) fresh.add(event);
      }
      if (fresh.isEmpty) continue;
      if (!session.allowGossip()) continue;
      session.enqueue(GossipFrame(events: fresh, hops: hops), high: true);
    }
  }

  void _trimSeen() {
    while (_seen.length > maxSeenEvents) {
      _seen.remove(_seen.keys.first);
    }
  }

  Future<void> _persistPending(SyncEvent event) async {
    try {
      await store.putPendingEvent(event.toRecord());
    } on Object catch (_) {
      // In-memory очередь продолжает работать; недостающее событие повторно
      // придёт через anti-entropy. Секреты и payload в лог не попадают.
    }
  }

  Future<void> _deletePending(String id) async {
    try {
      await store.deletePendingEvent(id);
    } on Object catch (_) {
      // Удаление повторится при следующем старте/trim; дубль отсеет store.
    }
  }

  Future<void> _trimPending() async {
    while (_pending.length > maxPendingEvents) {
      final id = _pending.keys.first;
      _pending.remove(id);
      await _deletePending(id);
    }
  }

  Future<void> drain() async {
    if (_closed) return;
    for (var round = 0; round < 128; round++) {
      final sessions = _links.values.toList();
      await Future.wait(sessions.map((session) => session.drain()));
      if (sessions.every((session) => session.isIdle)) return;
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _antiEntropyTimer?.cancel();
    _antiEntropyTimer = null;
    for (final session in _links.values.toList()) {
      await session.close();
    }
    _links.clear();
    await _changes.close();
  }
}

int _compare(SyncEvent a, SyncEvent b) => a.compareTo(b);

class _RangeRequestState {
  const _RangeRequestState({
    required this.key,
    required this.groupId,
    required this.fromHlc,
    required this.toHlc,
    this.channelId,
  });

  final String key;
  final GroupId groupId;
  final int fromHlc;
  final int toHlc;
  final ChannelId? channelId;
}

class _Outbound {
  _Outbound(this.frame);

  final SyncFrame frame;
  final Completer<void> completer = Completer<void>();
}

class _LinkSession {
  _LinkSession({required this.engine, required this.link});

  final SyncEngineImpl engine;
  final SyncLink link;

  final Queue<_Outbound> _high = Queue<_Outbound>();
  final Queue<_Outbound> _low = Queue<_Outbound>();
  final LinkedHashSet<String> _gossipSent = LinkedHashSet<String>();
  final Map<String, _RangeRequestState> _rangeRequests = {};

  StreamSubscription<Uint8List>? _subscription;
  Future<void> _incomingChain = Future<void>.value();
  Future<void>? _pumpFuture;
  bool _pumping = false;
  bool _closed = false;
  int _requestCounter = 0;

  double _gossipTokens = 200;
  late int _lastRefillMs = engine._nowMs();

  String get peerId => link.peerId;

  bool get isIdle {
    if (_pumpFuture != null) return false;
    if (_high.isNotEmpty || _low.isNotEmpty) return false;
    return true;
  }

  Future<void> start() async {
    _subscription = link.incoming.listen(
      (bytes) {
        _incomingChain = _incomingChain.then((_) => _handle(bytes));
      },
      onError: (_) {},
      onDone: () => unawaited(engine._onLinkClosed(this)),
    );
    await engine._onLinkReady(this);
  }

  Future<void> _handle(Uint8List bytes) async {
    if (_closed) return;
    final decoded = engine._frameCodec.decode(bytes);
    if (decoded.isErr) return;
    final frame = decoded.unwrap();
    try {
      switch (frame) {
        case SummaryFrame():
          await engine._onSummary(this, frame);
        case RangeRequestFrame():
          await engine._onRangeRequest(this, frame);
        case WindowRequestFrame():
          await engine._onWindowRequest(this, frame);
        case EventsFrame():
          await engine._onEvents(this, frame);
        case GossipFrame():
          await engine._onGossip(this, frame);
        case PingFrame():
          break;
      }
    } catch (_) {
      // Битый/несовместимый кадр не должен отравлять очередь входящих.
      // Anti-entropy восстановит недостающие события при следующем обмене.
    }
  }

  String nextRequestId() => '$peerId:${_requestCounter++}';

  void enqueue(SyncFrame frame, {bool high = false}) {
    if (_closed) return;
    final outbound = _Outbound(frame);
    final total = _high.length + _low.length;
    if (!high && total >= engine.maxOutboundQueue) {
      outbound.completer.complete();
      return;
    }
    if (high) {
      _high.add(outbound);
    } else {
      _low.add(outbound);
    }
    unawaited(_pump());
  }

  bool shouldGossip(String eventId) {
    if (_gossipSent.contains(eventId)) return false;
    _gossipSent.add(eventId);
    while (_gossipSent.length > 4096) {
      _gossipSent.remove(_gossipSent.first);
    }
    return true;
  }

  bool allowGossip() {
    final now = engine._nowMs();
    final elapsed = now - _lastRefillMs;
    if (elapsed > 0) {
      _gossipTokens = math.min(200, _gossipTokens + elapsed * 0.05);
      _lastRefillMs = now;
    }
    if (_gossipTokens < 1) return false;
    _gossipTokens -= 1;
    return true;
  }

  void registerRangeRequest(
    String requestId,
    String key,
    GroupId groupId,
    int fromHlc,
    int toHlc, {
    ChannelId? channelId,
  }) {
    _rangeRequests[requestId] = _RangeRequestState(
      key: key,
      groupId: groupId,
      fromHlc: fromHlc,
      toHlc: toHlc,
      channelId: channelId,
    );
  }

  _RangeRequestState? rangeRequest(String requestId) =>
      _rangeRequests[requestId];

  void completeRangeRequest(String requestId) {
    _rangeRequests.remove(requestId);
  }

  Future<void> _pump() {
    final existing = _pumpFuture;
    if (existing != null) return existing;
    if (_closed) return Future<void>.value();
    final future = _drainOutbound();
    _pumpFuture = future;
    return future.whenComplete(() {
      _pumpFuture = null;
      if (!_closed && (_high.isNotEmpty || _low.isNotEmpty)) {
        unawaited(_pump());
      }
    });
  }

  Future<void> _drainOutbound() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (!_closed && (_high.isNotEmpty || _low.isNotEmpty)) {
        final outbound = _high.isNotEmpty
            ? _high.removeFirst()
            : _low.removeFirst();
        try {
          final encoded = engine._frameCodec.encode(outbound.frame);
          if (encoded.isOk) {
            await link.send(encoded.unwrap());
          }
        } catch (_) {
          // Транспортная ошибка не должна валить сессию: anti-entropy
          // восстановит недостающие события при следующем обмене.
        } finally {
          if (!outbound.completer.isCompleted) {
            outbound.completer.complete();
          }
        }
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> drain() async {
    for (var round = 0; round < 128; round++) {
      final chain = _incomingChain;
      await chain;
      final pump = _pumpFuture;
      if (pump != null) await pump;
      if (identical(chain, _incomingChain) && _pumpFuture == null) return;
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    _high.clear();
    _low.clear();
    await link.close();
  }
}
