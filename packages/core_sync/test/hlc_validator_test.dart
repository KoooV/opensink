import 'package:test/test.dart';
import 'package:core_sync/core_sync.dart';

void main() {
  group('HlcValidator', () {
    test('accepts monotonically increasing hlc per peer', () {
      final v = HlcValidator();
      final now = 1_700_000_000_000;
      expect(v.validate('peer-a', now + 1000, now).isOk, isTrue);
      expect(v.validate('peer-a', now + 1001, now).isOk, isTrue);
      // Другой пиар — своя последовательность, может начинаться с любого значения в окне.
      expect(v.validate('peer-b', now + 500, now).isOk, isTrue);
    });

    test('rejects non-monotonic hlc for same peer', () {
      final v = HlcValidator();
      final now = 1_700_000_000_000;
      v.validate('peer-a', now + 1000, now);
      final r = v.validate('peer-a', now + 1000, now);
      expect(r.isErr, isTrue);
      expect(r.unwrapErr(), isA<NonMonotonicHlc>());

      final r2 = v.validate('peer-a', now + 999, now);
      expect(r2.isErr, isTrue);
      expect(r2.unwrapErr(), isA<NonMonotonicHlc>());
    });

    test('rejects negative hlc', () {
      final v = HlcValidator();
      final now = 1_700_000_000_000;
      expect(v.validate('peer-a', -1, now).isErr, isTrue);
      expect(v.validate('peer-a', -1, now).unwrapErr(), isA<NegativeHlc>());
    });

    test('rejects hlc beyond clock skew window', () {
      final v = HlcValidator();
      final now = 1_700_000_000_000;
      final future = now + HlcValidator.maxClockSkewMs + 1;
      expect(v.validate('peer-a', future, now).isErr, isTrue);
      expect(v.validate('peer-a', future, now).unwrapErr(), isA<ClockSkewExceeded>());

      final past = now - HlcValidator.maxClockSkewMs - 1;
      expect(v.validate('peer-a', past, now).isErr, isTrue);
      expect(v.validate('peer-a', past, now).unwrapErr(), isA<ClockSkewExceeded>());
    });

    test('accepts hlc within clock skew window', () {
      final v = HlcValidator();
      final now = 1_700_000_000_000;
      // Разные пиары — независимые последовательности, clock skew проверяется отдельно.
      expect(v.validate('peer-a', now + 1, now).isOk, isTrue);
      expect(v.validate('peer-b', now - 1, now).isOk, isTrue);
    });

    test('reset clears per-peer state', () {
      final v = HlcValidator();
      final now = 1_700_000_000_000;
      v.validate('peer-a', now + 1000, now);
      expect(v.validate('peer-a', now + 999, now).isErr, isTrue);
      v.reset('peer-a');
      expect(v.validate('peer-a', now + 999, now).isOk, isTrue);
    });
  });
}
