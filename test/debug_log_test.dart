import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/debug_log.dart';

void main() {
  group('DebugLog', () {
    setUp(() {
      DebugLog.instance
        ..enabled = false
        ..clear();
    });

    test('is a no-op while disabled', () {
      DebugLog.instance.info('nothing');
      expect(DebugLog.instance.isEmpty, isTrue);
      expect(DebugLog.instance.length, 0);
    });

    test('records entries with level and timestamp when enabled', () {
      DebugLog.instance.enabled = true;
      DebugLog.instance.info('hello');
      DebugLog.instance.warn('careful');
      DebugLog.instance.error('boom');
      expect(DebugLog.instance.length, 3);
      final lines = DebugLog.instance.dump().split('\n');
      expect(lines, hasLength(3));
      expect(lines[0], contains('INFO hello'));
      expect(lines[1], contains('WARN careful'));
      expect(lines[2], contains('ERROR boom'));
      // ISO-8601 timestamp prefix.
      expect(lines[0].substring(0, 10), matches(RegExp(r'\d{4}-\d{2}-\d{2}')));
    });

    test('the ring buffer caps at maxEntries', () {
      DebugLog.instance.enabled = true;
      for (var i = 0; i < DebugLog.maxEntries + 100; i++) {
        DebugLog.instance.info('entry $i');
      }
      expect(DebugLog.instance.length, DebugLog.maxEntries);
      // The oldest entries were evicted.
      expect(DebugLog.instance.dump(), isNot(contains('entry 0\n')));
      expect(
        DebugLog.instance.dump(),
        contains('entry ${DebugLog.maxEntries + 99}'),
      );
    });

    test('clear empties the buffer', () {
      DebugLog.instance.enabled = true;
      DebugLog.instance.info('x');
      DebugLog.instance.clear();
      expect(DebugLog.instance.isEmpty, isTrue);
    });
  });

  group('anonymizeDebugLog', () {
    test('quantizes the coordinate pairs in real log lines', () {
      const log = '2026-11-17T08:00:01.000 INFO fix accepted: 51.507400,-0.127800'
          ' speed=3.5 heading=90\n'
          '2026-11-17T08:00:02.000 WARN fix rejected: 51.5074,-0.1278\n'
          '2026-11-17T08:00:03.000 INFO locate: fix 48.858370,2.294480 age=120ms acc=8.0';
      final out = anonymizeDebugLog(log);
      expect(out, contains('fix accepted: 51.507,-0.128 speed=3.5 heading=90'));
      expect(out, contains('fix rejected: 51.507,-0.128'));
      expect(out, contains('locate: fix 48.858,2.294 age=120ms acc=8.0'));
    });

    test('leaves timestamps, levels and other numbers untouched', () {
      const log = '2026-11-17T08:00:01.123 INFO rotate: target=12.3 from=5.0 to=7.5\n'
          '2026-11-17T08:00:02.000 INFO import gpx: imported=3 duplicates=0 skipped=1 failed=0';
      expect(anonymizeDebugLog(log), log);
    });

    test('leaves out-of-range pairs as-is', () {
      const log = '2026-11-17T08:00:01.000 WARN fix rejected: 999.1,2.0';
      expect(anonymizeDebugLog(log), log);
    });

    test('is idempotent', () {
      const log = '2026-11-17T08:00:01.000 INFO fix accepted: 51.507400,-0.127800 speed=3.5 heading=90';
      final once = anonymizeDebugLog(log);
      expect(anonymizeDebugLog(once), once);
    });

    test('handles an empty log', () {
      expect(anonymizeDebugLog(''), '');
    });
  });
}
