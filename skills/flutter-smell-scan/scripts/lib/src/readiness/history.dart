/// Reads which Dart files changed together, from `git log`. Read-only.
library;

import 'dart:io';

import 'repo.dart';

/// How many recent non-merge commits to read.
const historyCommits = 1000;

/// Commits that touch more files than this are skipped: they are usually
/// renames, formatting or dependency bumps, not one change to one feature.
const maxFilesPerCommit = 30;

class History {
  History(this.commits, {this.error});

  /// The Dart files of each commit, newest first, as paths relative to the
  /// scan root. Empty when [error] is set.
  final List<List<String>> commits;

  /// Why the history could not be read, or null.
  final String? error;

  /// Commits that changed each file.
  late final Map<String, int> changes = () {
    final out = <String, int>{};
    for (final c in commits) {
      for (final f in c) {
        out[f] = (out[f] ?? 0) + 1;
      }
    }
    return out;
  }();

  static Future<History> read(Repo repo) async {
    if (!repo.isGit) return History(const [], error: 'not a git repository');
    final ProcessResult r;
    try {
      r = await Process.run(
        'git',
        [
          '-c',
          'core.quotepath=off',
          'log',
          '--no-merges',
          '--no-renames',
          '-n',
          '$historyCommits',
          '--relative',
          '--name-only',
          '--format=%x00',
          '--',
          '*.dart',
        ],
        workingDirectory: repo.root,
        environment: gitEnv,
      );
    } on ProcessException catch (e) {
      return History(const [], error: 'git log failed: ${e.message}');
    }
    if (r.exitCode != 0) {
      // A repository without commits exits 128.
      return History(const [], error: 'git log found no commits');
    }
    final commits = <List<String>>[];
    for (final block in (r.stdout as String).split('\x00')) {
      final files = [
        for (final line in block.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ];
      if (files.isNotEmpty) commits.add(files);
    }
    return History(commits);
  }
}
