import 'package:core_sync/core_sync.dart';
import 'package:test/test.dart';

void main() {
  group('HlcClock', () {
    test('tick is monotonic and uses physical time first', () {
      var now = 1000;
      final clock = HlcClock(nowMs: () => now);
      expect(clock.tick(), const Hlc(1000, 0));
      now = 1000;
      expect(clock.tick(), const Hlc(1000, 1));
      now = 900;
      expect(clock.tick(), const Hlc(1000, 2));
      now = 1100;
      expect(clock.tick(), const Hlc(1100, 0));
    });

    test('observe moves local clock beyond remote', () {
      var now = 1000;
      final clock = HlcClock(nowMs: () => now);
      clock.tick();
      final observed = clock.observe(const Hlc(2000, 5));
      expect(observed.compareTo(const Hlc(2000, 5)), greaterThan(0));
      expect(clock.last.compareTo(const Hlc(2000, 5)), greaterThan(0));
    });

    test(
      'observe with local ahead preserves physical and increments counter',
      () {
        var now = 5000;
        final clock = HlcClock(nowMs: () => now);
        clock.tick();
        now = 1000;
        final observed = clock.observe(const Hlc(2000, 1));
        expect(observed.physicalMs, 5000);
        expect(observed.counter, 1);
      },
    );

    test('comparison is lexicographic', () {
      expect(const Hlc(1, 9).compareTo(const Hlc(2, 0)), lessThan(0));
      expect(const Hlc(2, 1).compareTo(const Hlc(2, 0)), greaterThan(0));
      expect(const Hlc(2, 1), const Hlc(2, 1));
    });
  });
}
