import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/build_version.dart';

void main() {
  group('pickVersion', () {
    test('the baked GIT_COMMIT define wins', () {
      expect(
        AppVersion.pickVersion(define: 'abc1234', gitRevision: 'zzz'),
        'abc1234',
      );
    });

    test('whitespace around the define is tolerated', () {
      expect(AppVersion.pickVersion(define: '  abc1234 \n', gitRevision: null), 'abc1234');
    });

    test('falls back to the runtime git revision', () {
      expect(AppVersion.pickVersion(define: '', gitRevision: '0dd8041'), '0dd8041');
    });

    test('falls back to dev outside any checkout', () {
      expect(AppVersion.pickVersion(define: '', gitRevision: null), 'dev');
    });
  });

  group('probeGitRevision', () {
    test('finds this repository and agrees with git itself', () async {
      // The suite runs inside the project checkout, so the probe must find
      // it (from the working directory) and return the real short hash.
      final probed = await AppVersion.probeGitRevision();
      final git = await Process.run(
        'git',
        const ['rev-parse', '--short', 'HEAD'],
        workingDirectory: Directory.current.path,
      );
      expect(probed, (git.stdout as String).trim());
      expect(probed, matches(RegExp(r'^[0-9a-f]{7,40}$')));
    });
  });

  test('resolve() prefers the probe when no define was baked', () async {
    // GIT_COMMIT is not defined during `flutter test`, so resolve() must
    // agree with the probe; both hit the repository we run in.
    expect(await AppVersion.resolve(), await AppVersion.probeGitRevision());
  });

  test('resolve() is stable across calls', () async {
    expect(await AppVersion.resolve(), await AppVersion.resolve());
  });
}
