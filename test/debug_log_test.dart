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
}
