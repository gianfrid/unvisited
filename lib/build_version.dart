import 'dart:io';

/// Resolves the build time string shown in the UI: a human-readable
/// timestamp, by default the latest git commit's time.
///
/// Sources, in priority order:
///
/// 1. The `BUILD_TIME` dart-define (ISO 8601). Bake release builds with
///    `flutter build apk --dart-define=BUILD_TIME=$(git log -1 --format=%cI)`.
/// 2. The commit time of a git checkout reachable from the running process
///    (dev runs start inside the repository, so this always works on the
///    desktop and is always current - unlike a generated file it cannot go
///    stale).
/// 3. `dev` - e.g. an APK built without the define (no .git on a phone).
class AppVersion {
  static const _buildTimeDefine = String.fromEnvironment('BUILD_TIME');

  static Future<String>? _cached;

  /// The resolved build time; computed once per run.
  static Future<String> resolve() async =>
      _cached ??= Future.value(pickBuildTime(
        define: _buildTimeDefine,
        gitCommitTime: await probeGitCommitTime(),
      ));

  /// Pure decision + formatting step, public for unit tests.
  static String pickBuildTime({required String define, String? gitCommitTime}) {
    final baked = define.trim();
    if (baked.isNotEmpty) {
      // Lenient: a non-ISO custom string is shown as given; ISO timestamps
      // are reformatted for readability in the viewer's local time.
      return _humanize(baked) ?? baked;
    }
    if (gitCommitTime != null) {
      return _humanize(gitCommitTime) ?? gitCommitTime;
    }
    return 'dev';
  }

  /// `2026-11-12 17:41` in local time, or null when not an ISO timestamp.
  static String? _humanize(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return null;
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// ISO commit time of HEAD of the nearest enclosing checkout, or null when
  /// the process runs outside any checkout or git is unavailable. Local git
  /// only; this app makes no network calls.
  static Future<String?> probeGitCommitTime() async {
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
        const ['log', '-1', '--format=%cI'],
        workingDirectory: dir.path,
      );
      if (result.exitCode == 0) {
        final time = (result.stdout as String).trim();
        if (time.isNotEmpty) return time;
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
