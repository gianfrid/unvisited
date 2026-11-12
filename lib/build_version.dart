import 'dart:io';

/// Resolves the build version string shown in the UI.
///
/// Sources, in priority order:
///
/// 1. The `GIT_COMMIT` dart-define. Bake release builds with
///    `flutter build apk --dart-define=GIT_COMMIT=$(git rev-parse --short HEAD)`.
/// 2. The commit of a git checkout reachable from the running process
///    (dev runs start inside the repository, so this always works on the
///    desktop and is always current - unlike a generated file it cannot
///    go stale).
/// 3. `dev` - e.g. an APK built without the define (no .git on a phone).
class AppVersion {
  static const _gitCommitDefine = String.fromEnvironment('GIT_COMMIT');

  static Future<String>? _cached;

  /// The resolved version; computed once per run.
  static Future<String> resolve() => _cached ??= _resolve();

  static Future<String> _resolve() async =>
      pickVersion(define: _gitCommitDefine, gitRevision: await probeGitRevision());

  /// Pure decision step, public for unit tests.
  static String pickVersion({required String define, String? gitRevision}) {
    final baked = define.trim();
    if (baked.isNotEmpty) return baked;
    return gitRevision ?? 'dev';
  }

  /// Short hash of HEAD of the nearest enclosing checkout, or null when the
  /// process runs outside any checkout or git is unavailable. Local git only;
  /// this app makes no network calls.
  static Future<String?> probeGitRevision() async {
    if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      return null;
    }
    try {
      for (final dir in _gitCandidateDirs()) {
        final result = await _runGit(dir);
        if (result != null) return result;
      }
    } on Exception {
      // git not installed or unreadable directories: fall through.
    }
    return null;
  }

  static Future<String?> _runGit(Directory dir) async {
    try {
      final result = await Process.run(
        'git',
        const ['rev-parse', '--short', 'HEAD'],
        workingDirectory: dir.path,
      );
      if (result.exitCode == 0) {
        final rev = (result.stdout as String).trim();
        if (rev.isNotEmpty) return rev;
      }
    } on ProcessException {
      // git binary missing on this host.
      return null;
    }
    return null;
  }

  /// Directories to try: the working directory first, then the executable's
  /// ancestor directories (git walks up from each, so a build tree nested in
  /// a checkout is found from the launched binary too).
  static List<Directory> _gitCandidateDirs() {
    final dirs = <Directory>[Directory.current];
    try {
      var dir = File(Platform.resolvedExecutable).parent;
      while (true) {
        dirs.add(dir);
        final parent = dir.parent;
        if (parent.path == dir.path) break; // reached the filesystem root
        dir = parent;
      }
    } on UnsupportedError {
      // resolvedExecutable unavailable; the working directory is all we have
    }
    return dirs;
  }
}
