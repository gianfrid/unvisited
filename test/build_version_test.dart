import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/build_version.dart';

/// Same shape AppVersion formats with, to build timezone-independent
/// expectations from a fixed-offset input.
String humanized(String iso) {
  final local = DateTime.parse(iso).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

void main() {
  group('AppVersion.pickBuildTime', () {
    test('the baked BUILD_TIME define is humanized in local time', () {
      const iso = '2026-11-12T17:41:00+01:00';
      expect(
        AppVersion.pickBuildTime(define: iso, gitCommitTime: null),
        humanized(iso),
      );
    });

    test('an empty define falls back to the git commit time', () {
      const iso = '2026-11-12T09:15:00+01:00';
      expect(
        AppVersion.pickBuildTime(define: '', gitCommitTime: iso),
        humanized(iso),
      );
    });

    test('a non-ISO baked define is shown verbatim', () {
      expect(
        AppVersion.pickBuildTime(define: 'custom-label', gitCommitTime: null),
        'custom-label',
      );
    });

    test('falls back to dev outside any checkout', () {
      expect(AppVersion.pickBuildTime(define: '', gitCommitTime: null), 'dev');
    });
  });

  group('AppVersion.probeGitCommitTime', () {
    test('finds this repository and agrees with git itself', () async {
      // The suite runs inside the project checkout, so the probe must find
      // it (from the working directory) and return the real commit time.
      final probed = await AppVersion.probeGitCommitTime();
      final git = await Process.run(
        'git',
        const ['log', '-1', '--format=%cI'],
        workingDirectory: Directory.current.path,
      );
      expect(probed, isNotNull);
      expect(probed, (git.stdout as String).trim());
    });
  });

  test('resolve() humanizes the probed commit time', () async {
    // BUILD_TIME is not defined during `flutter test`, so resolve() must be
    // the humanized commit time of the repository we run in.
    final resolved = await AppVersion.resolve();
    final probed = await AppVersion.probeGitCommitTime();
    expect(resolved, isNot('dev'));
    expect(resolved, humanized(probed!));
  });

  test('resolve() is stable across calls', () async {
    expect(await AppVersion.resolve(), await AppVersion.resolve());
  });
}
