/// A read-only view of the files in the scanned project, as an agent's
/// search tools see them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Git must never take an optional lock or refresh the index of the scanned
/// project, because the scan is read-only.
const gitEnv = {'GIT_OPTIONAL_LOCKS': '0'};

/// Directory names that never hold project source.
const ignoredSegments = {
  '.dart_tool',
  '.git',
  'build',
  'node_modules',
  'Pods',
  '.pub-cache',
  '.symlinks',
};

class Repo {
  Repo._(this.root, this.files, this.isGit);

  final String root;

  /// Paths relative to [root], with `/` separators. In a git repository these
  /// are the tracked files plus untracked files that are not ignored: what
  /// ripgrep (and so an agent's Grep tool) searches.
  final List<String> files;
  final bool isGit;

  late final Set<String> _fileSet = files.toSet();
  final _cache = <String, String?>{};

  static Future<Repo> open(String root) async {
    try {
      final r = await Process.run(
        'git',
        ['ls-files', '-z', '--cached', '--others', '--exclude-standard'],
        workingDirectory: root,
        environment: gitEnv,
      );
      if (r.exitCode == 0) {
        final files =
            (r.stdout as String)
                .split('\x00')
                .where((f) => f.isNotEmpty)
                .toSet()
                .toList()
              ..sort();
        return Repo._(root, files, true);
      }
    } on ProcessException {
      // git is not installed; walk the tree instead.
    }
    return Repo._(root, _walk(root), false);
  }

  static List<String> _walk(String root) {
    final out = <String>[];
    void walk(Directory dir) {
      for (final e in dir.listSync(followLinks: false)) {
        final name = p.basename(e.path);
        if (e is Directory) {
          if (ignoredSegments.contains(name)) continue;
          walk(e);
        } else if (e is File) {
          out.add(p.relative(e.path, from: root).replaceAll(r'\', '/'));
        }
      }
    }

    walk(Directory(root));
    return out..sort();
  }

  /// True when [rel] is a file or directory on disk, tracked or not.
  bool existsOnDisk(String rel) {
    final full = p.join(root, rel);
    return FileSystemEntity.typeSync(full) != FileSystemEntityType.notFound;
  }

  bool isVisible(String rel) => _fileSet.contains(rel);

  /// File size in bytes, or 0 when it does not exist.
  int size(String rel) {
    final f = File(p.join(root, rel));
    return f.existsSync() ? f.lengthSync() : 0;
  }

  /// The file's text, or null when it does not exist or is not text.
  String? read(String rel) => _cache.putIfAbsent(rel, () {
    final f = File(p.join(root, rel));
    if (!f.existsSync()) return null;
    try {
      return f.readAsStringSync();
    } on FileSystemException {
      return null;
    }
  });

  YamlNode? readYaml(String rel) {
    final text = read(rel);
    if (text == null) return null;
    try {
      return loadYamlNode(text);
    } on YamlException {
      return null;
    }
  }

  /// Visible files whose path has no [ignoredSegments] directory.
  Iterable<String> get sourceFiles =>
      files.where((f) => !f.split('/').any(ignoredSegments.contains));

  /// Runs `git check-ignore` on [paths] and returns the ignored ones.
  Future<Set<String>> ignored(Iterable<String> paths) async {
    if (!isGit || paths.isEmpty) return {};
    try {
      final proc = await Process.start(
        'git',
        ['check-ignore', '--stdin', '-z', '--no-index'],
        workingDirectory: root,
        environment: gitEnv,
      );
      proc.stdin.write(paths.join('\x00'));
      await proc.stdin.close();
      final out = await proc.stdout.transform(utf8.decoder).join();
      await proc.exitCode;
      return out.split('\x00').where((s) => s.isNotEmpty).toSet();
    } on ProcessException {
      return {};
    }
  }
}

/// A package (a directory with pubspec.yaml) inside the scanned project.
class LocalPackage {
  LocalPackage(this.dir, this.name, this.pubspec, {required this.vendored});

  /// Relative to the scan root; `.` for the root package.
  final String dir;
  final String? name;
  final Map pubspec;

  /// A copy of third-party code: it is not a workspace or melos member, and
  /// it declares a homepage or repository, or ships its own LICENSE and is
  /// not marked `publish_to: none`.
  final bool vendored;

  bool contains(String rel) => dir == '.' || p.isWithin(dir, rel);

  Iterable<String> get dependencyNames sync* {
    for (final key in const [
      'dependencies',
      'dev_dependencies',
      'dependency_overrides',
    ]) {
      final deps = pubspec[key];
      if (deps is Map) yield* deps.keys.map((k) => '$k');
    }
  }

  bool dependsOn(String name) => dependencyNames.contains(name);
}

List<LocalPackage> findLocalPackages(Repo repo) {
  final members = _workspaceMembers(repo);
  final result = <LocalPackage>[];
  for (final f in repo.sourceFiles) {
    if (p.basename(f) != 'pubspec.yaml') continue;
    final dir = p.dirname(f);
    // Example apps inside packages are demos, not project code.
    if (dir.split('/').contains('example')) continue;
    final yaml = repo.readYaml(f);
    final map = yaml is YamlMap ? yaml : YamlMap();
    final hasLicense = repo.files.any(
      (x) =>
          p.dirname(x) == dir &&
          p.basename(x).toUpperCase().startsWith('LICENSE'),
    );
    // Workspace and melos members are first-party, even when they declare
    // a repository (every package in an open-source monorepo does).
    final vendored =
        dir != '.' &&
        !members.any((m) => m.hasMatch(dir)) &&
        (map['homepage'] != null ||
            map['repository'] != null ||
            (hasLicense && map['publish_to'] != 'none'));
    result.add(
      LocalPackage(dir, map['name'] as String?, map, vendored: vendored),
    );
  }
  return result;
}

/// Directory patterns of pub workspace members (`workspace:` in the root
/// pubspec) and melos packages (`packages:` in melos.yaml or the pubspec's
/// `melos:` section).
List<RegExp> _workspaceMembers(Repo repo) {
  final globs = <String>[];
  final pubspec = repo.readYaml('pubspec.yaml');
  if (pubspec is YamlMap) {
    final ws = pubspec['workspace'];
    if (ws is YamlList) globs.addAll(ws.map((e) => '$e'));
    final melos = pubspec['melos'];
    if (melos is YamlMap && melos['packages'] is YamlList) {
      globs.addAll((melos['packages'] as YamlList).map((e) => '$e'));
    }
  }
  final melos = repo.readYaml('melos.yaml');
  if (melos is YamlMap && melos['packages'] is YamlList) {
    globs.addAll((melos['packages'] as YamlList).map((e) => '$e'));
  }
  return [for (final g in globs) _globToRegExp(g)];
}

RegExp _globToRegExp(String glob) {
  final g = glob
      .replaceFirst(RegExp(r'^\./'), '')
      .replaceFirst(RegExp(r'/+$'), '');
  final buf = StringBuffer('^');
  for (var i = 0; i < g.length; i++) {
    final ch = g[i];
    if (ch == '*') {
      final double = i + 1 < g.length && g[i + 1] == '*';
      buf.write(double ? '.*' : '[^/]*');
      if (double) i++;
    } else {
      buf.write(RegExp.escape(ch));
    }
  }
  buf.write(r'$');
  return RegExp(buf.toString());
}

/// The innermost package that holds [rel].
LocalPackage? owningPackage(String rel, List<LocalPackage> packages) {
  LocalPackage? best;
  for (final pkg in packages) {
    if (!pkg.contains(rel)) continue;
    if (best == null || best.dir == '.' || pkg.dir.length > best.dir.length) {
      best = pkg;
    }
  }
  return best;
}

bool isVendored(String rel, List<LocalPackage> packages) =>
    owningPackage(rel, packages)?.vendored ?? false;

/// Text with full-line `#` comments blanked (YAML, shell, Python, Ruby).
/// Lines stay in place, so line numbers still match the file.
String stripHashComments(String text) => text
    .split('\n')
    .map(
      (l) => l.trimLeft().startsWith('#') && !l.trimLeft().startsWith('#!')
          ? ''
          : l,
    )
    .join('\n');

/// Joins shell lines that end with a `\` continuation. The joined command
/// stays on its first line and blank lines replace the rest, so line numbers
/// still match the file.
String joinContinuations(String text) {
  final out = <String>[];
  final buf = StringBuffer();
  var joined = 0;
  for (final line in text.split('\n')) {
    final trimmed = line.trimRight();
    if (trimmed.endsWith('\\')) {
      buf.write('${trimmed.substring(0, trimmed.length - 1).trimLeft()} ');
      joined++;
      continue;
    }
    buf.write(joined > 0 ? line.trimLeft() : line);
    out
      ..add(buf.toString())
      ..addAll(List.filled(joined, ''));
    buf.clear();
    joined = 0;
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out.join('\n');
}
