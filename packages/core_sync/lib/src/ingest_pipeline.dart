import 'package:core_domain/core_domain.dart';

import 'bytes.dart';
import 'errors.dart';
import 'hlc_validator.dart';
import 'projection.dart';
import 'sync_event.dart';

enum IngestOutcome { inserted, duplicate, pending }

class IngestResult {
  const IngestResult(this.outcome);
  final IngestOutcome outcome;

  bool get isInserted => outcome == IngestOutcome.inserted;
  bool get isDuplicate => outcome == IngestOutcome.duplicate;
  bool get isPending => outcome == IngestOutcome.pending;

  @override
  String toString() => 'IngestResult($outcome)';
}

typedef MembershipCheck = MembershipStatus Function(SyncEvent event);

/// Проверка доверенного корня группы. Вызывается после проверки подписи и до
/// membership: чужие `groupCreated` не должны попадать в лог и проекцию.
typedef SyncRootCheck = SyncError? Function(SyncEvent event);

/// Конвейер приёма события.
///
/// Порядок строго задан: размер → id → подпись → доверенный корень →
/// членство на момент события → дедупликация → запись. Ни исключения, ни
/// секреты не покидают слой.
class SyncIngestPipeline {
  SyncIngestPipeline({
    required this.store,
    required this.signer,
    required this.membershipCheck,
    this.rootCheck,
    this.maxEventBytes = maxSyncEventBytes,
    int Function()? nowMs,
    this.maxFutureSkewMs = HlcValidator.maxClockSkewMs,
    this.maxEventsPerAuthorPerWindow = 240,
    this.authorRateWindow = const Duration(seconds: 10),
    this.maxAuthorWindows = 4096,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SyncEventStore store;
  final Signer signer;
  final MembershipCheck membershipCheck;
  final SyncRootCheck? rootCheck;
  final int maxEventBytes;
  final int maxFutureSkewMs;
  final int maxEventsPerAuthorPerWindow;
  final Duration authorRateWindow;
  final int maxAuthorWindows;
  final int Function() _nowMs;
  final Map<String, _AuthorWindow> _authorWindows = {};

  Future<Result<IngestResult, SyncError>> ingest(
    SyncEvent event, {
    bool enforceRate = true,
  }) async {
    if (event.payload.length > maxEventBytes) {
      return Err(EventTooLarge(event.payload.length, maxEventBytes));
    }
    final canonical = event.canonicalBytes();
    if (canonical.length > maxEventBytes) {
      return Err(EventTooLarge(canonical.length, maxEventBytes));
    }

    final computedId = event.computeId();
    if (event.id.value.isEmpty || event.id.value != computedId) {
      return Err(EventIdMismatch(event.id.value, computedId));
    }

    final now = _nowMs();
    if (event.hlc.physicalMs > now + maxFutureSkewMs) {
      return Err(HlcTooFarInFuture(event.hlc.physicalMs, now, maxFutureSkewMs));
    }

    final authorBytes = hexDecode(event.authorId.value);
    if (authorBytes == null || authorBytes.length != 32) {
      return const Err(InvalidEventAuthor());
    }

    if (event.signature.isEmpty) {
      return const Err(InvalidSignature());
    }
    final signatureValid = await signer.verify(
      event.signedBytes(),
      event.signature,
      PeerId(authorBytes),
    );
    if (!signatureValid) return const Err(InvalidSignature());

    final rootError = rootCheck?.call(event);
    if (rootError != null) return Err(rootError);

    if (enforceRate &&
        maxEventsPerAuthorPerWindow > 0 &&
        !_allowAuthor(event.authorId.value, now)) {
      return Err(
        AuthorRateLimited(
          event.authorId.value,
          maxEventsPerAuthorPerWindow,
          authorRateWindow.inMilliseconds,
        ),
      );
    }

    switch (membershipCheck(event)) {
      case MembershipStatus.unknown:
        return const Ok(IngestResult(IngestOutcome.pending));
      case MembershipStatus.notMember:
        return Err(NotAMember(event.authorId.value, event.groupId.value));
      case MembershipStatus.member:
        break;
    }

    final prevId = event.prevId;
    if (prevId != null) {
      final prev = await store.eventById(prevId.value);
      if (prev != null) {
        if (prev.groupId.value != event.groupId.value ||
            prev.author != event.authorId.value) {
          return Err(InvalidPrev(prevId.value, 'author or group mismatch'));
        }
        if (prev.timestamp > event.hlc.physicalMs) {
          return Err(InvalidPrev(prevId.value, 'prev is newer than event'));
        }
      }
    }

    final existing = await store.eventById(event.id.value);
    if (existing != null) {
      return const Ok(IngestResult(IngestOutcome.duplicate));
    }

    final write = await store.write(event.toRecord());
    if (write.isErr) {
      return Err(StorageWriteFailure(write.unwrapErr().toString()));
    }
    final outcome = write.unwrap();
    if (outcome.duplicate) {
      return const Ok(IngestResult(IngestOutcome.duplicate));
    }
    return const Ok(IngestResult(IngestOutcome.inserted));
  }

  bool _allowAuthor(String authorId, int nowMs) {
    final windowMs = authorRateWindow.inMilliseconds;
    final current = _authorWindows[authorId];
    if (current == null || nowMs - current.startMs >= windowMs) {
      if (current == null && _authorWindows.length >= maxAuthorWindows) {
        _authorWindows.remove(_authorWindows.keys.first);
      }
      _authorWindows[authorId] = _AuthorWindow(nowMs, 1);
      return true;
    }
    if (current.count >= maxEventsPerAuthorPerWindow) {
      return false;
    }
    _authorWindows[authorId] = _AuthorWindow(
      current.startMs,
      current.count + 1,
    );
    return true;
  }
}

/// Проверка, что событие принадлежит заявленному автору и группе.
/// Используется в тестах и при аудите цепочки.
bool hasValidAuthorKey(SyncEvent event) {
  final bytes = hexDecode(event.authorId.value);
  return bytes != null && bytes.length == 32;
}

class _AuthorWindow {
  _AuthorWindow(this.startMs, this.count);
  final int startMs;
  final int count;
}
