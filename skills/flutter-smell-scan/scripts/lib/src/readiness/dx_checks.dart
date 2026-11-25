/// Developer-experience checks: lint config, formatting, CI and setup docs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'ax_checks.dart';
import 'model.dart';
import 'repo.dart';

/// Lints whose absence lets common Flutter bugs through. Both are in the
/// stock `flutter_lints` set, so a default project passes.
const keyLints = ['use_build_context_synchronously', 'avoid_print'];

/// Key lints that only mean something in Flutter code.
const _flutterOnlyLints = {'use_build_context_synchronously'};

/// Worth turning on, but not in `flutter_lints`. Reported, not scored.
const recommendedLints = ['prefer_const_constructors', 'unawaited_futures'];

class _LintConfig {
  final rules = <String, bool>{};
  final chain = <String>[];
  final unresolved = <String>[];
  final plugins = <String>{};
  final excludes = <String>[];
  Object? pageWidth;
}

/// Maps package names to their `lib/` directory for the package in
/// [pkgDir]: from the nearest `.dart_tool/package_config.json` at or above
/// it, falling back to local packages.
Map<String, String> _packageLibDirs(ReadinessContext c, String pkgDir) {
  final out = <String, String>{};
  for (final pkg in c.packages) {
    if (pkg.name != null) {
      out[pkg.name!] = p.join(c.repo.root, pkg.dir, 'lib');
    }
  }
  var dir = p.normalize(p.join(c.repo.root, pkgDir));
  File? configFile;
  while (true) {
    final f = File(p.join(dir, '.dart_tool', 'package_config.json'));
    if (f.existsSync()) {
      configFile = f;
      break;
    }
    if (p.equals(dir, c.repo.root) || p.dirname(dir) == dir) break;
    dir = p.dirname(dir);
  }
  if (configFile == null) return out;
  try {
    final json = jsonDecode(configFile.readAsStringSync()) as Map;
    final base = configFile.uri;
    for (final pkg in (json['packages'] as List? ?? const [])) {
      final m = pkg as Map;
      final rootUri = base.resolve(
        '${m['rootUri']}'.endsWith('/')
            ? '${m['rootUri']}'
            : '${m['rootUri']}/',
      );
      final libUri = rootUri.resolve('${m['packageUri'] ?? 'lib/'}');
      out['${m['name']}'] = libUri.toFilePath();
    }
  } on FormatException {
    // Keep the local fallback.
  }
  return out;
}

void _loadLintFile(
  String absPath,
  String label,
  Map<String, String> libDirs,
  _LintConfig cfg,
  int depth,
) {
  if (depth > 6) return;
  final file = File(absPath);
  if (!file.existsSync()) {
    cfg.unresolved.add(label);
    return;
  }
  cfg.chain.add(label);
  YamlNode? doc;
  try {
    doc = loadYamlNode(file.readAsStringSync());
  } on YamlException {
    cfg.unresolved.add('$label (bad YAML)');
    return;
  }
  if (doc is! YamlMap) return;

  final include = doc['include'];
  for (final inc in include is YamlList ? include : [include]) {
    if (inc is! String) continue;
    if (inc.startsWith('package:')) {
      final rest = inc.substring(8);
      final slash = rest.indexOf('/');
      final lib = slash < 0 ? null : libDirs[rest.substring(0, slash)];
      if (lib == null) {
        cfg.unresolved.add(inc);
      } else {
        _loadLintFile(
          p.join(lib, rest.substring(slash + 1)),
          inc,
          libDirs,
          cfg,
          depth + 1,
        );
      }
    } else {
      _loadLintFile(
        p.normalize(p.join(p.dirname(absPath), inc)),
        inc,
        libDirs,
        cfg,
        depth + 1,
      );
    }
  }

  final linter = doc['linter'];
  final rules = linter is YamlMap ? linter['rules'] : null;
  if (rules is YamlList) {
    for (final r in rules) {
      cfg.rules['$r'] = true;
    }
  } else if (rules is YamlMap) {
    rules.forEach((k, v) => cfg.rules['$k'] = v != false);
  }
  final analyzer = doc['analyzer'];
  if (analyzer is YamlMap) {
    final errors = analyzer['errors'];
    if (errors is YamlMap) {
      errors.forEach((k, v) {
        if (v == 'ignore') cfg.rules['$k'] = false;
      });
    }
    final plugins = analyzer['plugins'];
    if (plugins is YamlList) cfg.plugins.addAll(plugins.map((e) => '$e'));
    final exclude = analyzer['exclude'];
    if (exclude is YamlList) cfg.excludes.addAll(exclude.map((e) => '$e'));
  }
  final plugins = doc['plugins'];
  if (plugins is YamlMap) cfg.plugins.addAll(plugins.keys.map((k) => '$k'));
  final formatter = doc['formatter'];
  if (formatter is YamlMap) cfg.pageWidth ??= formatter['page_width'];
}

ReadinessCheck lintConfigCheck(ReadinessContext c) {
  // The root file, plus a file in each first-party package. A package with
  // no file of its own uses the nearest one above it.
  final owners = [
    if (c.repo.existsOnDisk('analysis_options.yaml')) '.',
    for (final pkg in c.packages)
      if (pkg.dir != '.' &&
          !pkg.vendored &&
          c.repo.existsOnDisk(p.join(pkg.dir, 'analysis_options.yaml')))
        pkg.dir,
  ];
  // Only packages with Dart code need a config; a workspace root may have
  // none.
  final withCode = {
    for (final r in c.reports) owningPackage(r.path, c.packages)?.dir,
  };
  final uncovered = [
    for (final pkg in c.packages)
      if (!pkg.vendored &&
          withCode.contains(pkg.dir) &&
          !owners.any(
            (o) => o == '.' || o == pkg.dir || p.isWithin(o, pkg.dir),
          ))
        pkg.dir,
  ];
  if (owners.isEmpty) {
    return ReadinessCheck(
      id: 'lint-config',
      area: 'dx',
      status: CheckStatus.fail,
      summary:
          'The project has no analysis_options.yaml, so only the '
          'analyzer defaults apply.',
      fix:
          'Add analysis_options.yaml that includes '
          '`package:flutter_lints/flutter.yaml` (or very_good_analysis), and '
          'exclude generated files.',
    );
  }

  final configs = <String, _LintConfig>{};
  for (final dir in owners) {
    final cfg = _LintConfig();
    final rel = p.normalize(p.join(dir, 'analysis_options.yaml'));
    _loadLintFile(
      p.join(c.repo.root, rel),
      rel,
      _packageLibDirs(c, dir),
      cfg,
      0,
    );
    configs[rel] = cfg;
  }

  var suppressions = 0, lines = 0;
  final byRule = <String, int>{};
  for (final r in c.reports) {
    if (c.vendored(r.path)) continue;
    lines += r.lines;
    suppressions += r.suppressions;
    r.suppressedRules.forEach((k, v) => byRule[k] = (byRule[k] ?? 0) + v);
  }
  final topRules = byRule.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final perK = lines == 0 ? 0.0 : suppressions * 1000 / lines;

  // A config covers Flutter code when its own package, or (for the root
  // file) a package with no config of its own, depends on Flutter.
  bool coversFlutter(String file) {
    final dir = p.dirname(file);
    return c.packages.any(
      (pkg) =>
          !pkg.vendored &&
          pkg.dependsOn('flutter') &&
          (pkg.dir == dir ||
              (dir == '.' &&
                  !owners.any(
                    (o) => o != '.' && (o == pkg.dir || p.isWithin(o, pkg.dir)),
                  ))),
    );
  }

  List<String> off(_LintConfig cfg, List<String> lints) => [
    for (final k in lints)
      if (cfg.rules[k] != true) k,
  ];
  List<String> keyOffFor(String file, _LintConfig cfg) => [
    for (final k in off(cfg, keyLints))
      if (coversFlutter(file) || !_flutterOnlyLints.contains(k)) k,
  ];
  final unresolved = {
    for (final e in configs.entries)
      if (e.value.unresolved.isNotEmpty) e.key: e.value.unresolved,
  };
  final keyOff = {
    for (final e in configs.entries)
      if (e.value.unresolved.isEmpty && keyOffFor(e.key, e.value).isNotEmpty)
        e.key: keyOffFor(e.key, e.value),
  };

  final problems = [
    for (final e in keyOff.entries)
      '${e.key} turns off key lints: ${e.value.join(', ')}.',
    if (perK > 2)
      'The code silences the analyzer often '
          '(${perK.toStringAsFixed(1)} per 1000 lines).',
    if (uncovered.isNotEmpty)
      'No analysis_options.yaml applies to: ${uncovered.join(', ')}.',
  ];
  final CheckStatus status;
  final String summary;
  if (problems.isNotEmpty) {
    status = CheckStatus.warn;
    summary = problems.join(' ');
  } else if (unresolved.isNotEmpty) {
    status = CheckStatus.unknown;
    summary =
        'Could not read an included lint config '
        '(${unresolved.values.expand((x) => x).toSet().join(', ')}), so the '
        'enabled rules are unknown. Run `pub get` with the user\'s OK, or '
        'read the include by hand.';
  } else {
    status = CheckStatus.pass;
    summary =
        'Lint rules are set, key lints are on, and suppressions are rare.';
  }

  return ReadinessCheck(
    id: 'lint-config',
    area: 'dx',
    status: status,
    summary: summary,
    evidence: [
      for (final e in configs.entries.take(8))
        _lintEvidence(
          e.key,
          e.value,
          keyOffFor(e.key, e.value),
          off(e.value, recommendedLints),
        ),
      if (configs.length > 8) '${configs.length - 8} more config files.',
      '$suppressions `// ignore` comments in $lines lines'
          '${topRules.isEmpty ? '' : '; most silenced: ${topRules.take(5).map((e) => '${e.key} (${e.value})').join(', ')}'}.',
    ],
    fix:
        'Turn on the key lints, fix the code they flag, and replace '
        'repeated `// ignore` comments with a code fix or a documented '
        'exception in analysis_options.yaml.',
    details: {
      'configs': {
        for (final e in configs.entries)
          e.key: {
            'chain': e.value.chain,
            'unresolved': e.value.unresolved,
            'rulesOff': [
              for (final r in e.value.rules.entries)
                if (!r.value) r.key,
            ],
            'keyLintsOff': e.value.unresolved.isEmpty
                ? keyOffFor(e.key, e.value)
                : null,
            'recommendedLintsOff': e.value.unresolved.isEmpty
                ? off(e.value, recommendedLints)
                : null,
            'plugins': e.value.plugins.toList(),
            'excludes': e.value.excludes,
            'pageWidth': e.value.pageWidth,
          },
      },
      'suppressions': suppressions,
      'suppressedRules': {for (final e in topRules.take(20)) e.key: e.value},
    },
  );
}

String _lintEvidence(
  String file,
  _LintConfig cfg,
  List<String> keyOff,
  List<String> recommendedOff,
) {
  final on = cfg.rules.values.where((v) => v).length;
  final offCount = cfg.rules.values.where((v) => !v).length;
  final parts = [
    'chain ${cfg.chain.join(' -> ')}',
    if (cfg.unresolved.isNotEmpty) 'unreadable ${cfg.unresolved.join(', ')}',
    '$on rules on, $offCount off',
    if (cfg.unresolved.isEmpty) ...[
      'key lints off: ${keyOff.join(', ').ifEmpty('none')}',
      'recommended off: ${recommendedOff.join(', ').ifEmpty('none')}',
    ],
    if (cfg.plugins.isNotEmpty) 'plugins ${cfg.plugins.join(', ')}',
  ];
  return '$file: ${parts.join('; ')}.';
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

const _platformDirs = {'ios', 'android', 'macos', 'linux', 'windows', 'web'};

Future<ReadinessCheck> formatCheck(ReadinessContext c) async {
  final root = c.repo.root;
  String dart;
  final fvmSdk = p.join(root, '.fvm', 'flutter_sdk');
  final pinned = [
    '.fvmrc',
    '.fvm/fvm_config.json',
  ].where(c.repo.existsOnDisk).toList();
  if (FileSystemEntity.typeSync(fvmSdk) != FileSystemEntityType.notFound) {
    // The raw dart binary: the `bin/dart` wrapper can update the SDK cache.
    dart = p.join(fvmSdk, 'bin', 'cache', 'dart-sdk', 'bin', 'dart');
    if (!File(dart).existsSync()) {
      return _formatUnknown(
        'The FVM-pinned SDK in .fvm/flutter_sdk has not downloaded its Dart '
        'SDK yet, so the formatter version is unknown.',
      );
    }
  } else if (pinned.isNotEmpty) {
    return _formatUnknown(
      'The Flutter version is pinned (${pinned.join(', ')}) but '
      '.fvm/flutter_sdk is missing. Formatter output differs between Dart '
      'versions, so the check was skipped.',
    );
  } else {
    dart = 'dart';
  }

  final files = <String>[];
  // Without a package config, `dart format` assumes the newest language
  // version, whose style differs from Dart < 3.7. Those files would all look
  // unformatted, so they are skipped.
  final unresolved = <String>{};
  final resolvedCache = <String, bool>{};
  for (final f in c.repo.sourceFiles) {
    if (!f.endsWith('.dart') || isGeneratedPath(f) || c.vendored(f)) continue;
    final pkg = owningPackage(f, c.packages);
    final inner = pkg == null || pkg.dir == '.'
        ? f
        : p.relative(f, from: pkg.dir);
    final first = inner.split('/').first;
    if (_platformDirs.contains(first) || first == 'example') continue;
    if (!c.repo.existsOnDisk(f)) continue;
    final pkgDir = pkg?.dir ?? '.';
    if (!resolvedCache.putIfAbsent(
      pkgDir,
      () => _hasPackageConfig(c.repo.root, pkgDir),
    )) {
      unresolved.add(pkgDir);
      continue;
    }
    files.add(f);
  }
  if (files.isEmpty && unresolved.isNotEmpty) {
    return _formatUnknown(
      'No package has a .dart_tool/package_config.json (pub get has not '
      'run), so the formatter cannot tell the language version.',
    );
  }
  if (files.isEmpty) return _formatUnknown('No Dart files to check.');

  final changed = <String>[];
  for (var i = 0; i < files.length; i += 400) {
    final chunk = files.sublist(i, (i + 400).clamp(0, files.length));
    final ProcessResult r;
    try {
      r = await Process.run(dart, [
        'format',
        '--output=none',
        '--set-exit-if-changed',
        ...chunk,
      ], workingDirectory: root);
    } on ProcessException catch (e) {
      return _formatUnknown('Could not start `$dart format`: ${e.message}');
    }
    final out = '${r.stdout}';
    if (r.exitCode != 0 && r.exitCode != 1) {
      return _formatUnknown(
        '`dart format` failed (exit ${r.exitCode}): '
        '${'${r.stderr}'.trim().split('\n').take(3).join(' ')}',
      );
    }
    changed.addAll(
      RegExp(
        r'^Changed (.+)$',
        multiLine: true,
      ).allMatches(out).map((m) => m.group(1)!.trim()),
    );
  }

  final status = changed.isEmpty
      ? CheckStatus.pass
      : changed.length * 10 > files.length
      ? CheckStatus.fail
      : CheckStatus.warn;
  return ReadinessCheck(
    id: 'format',
    area: 'dx',
    status: status,
    summary: changed.isEmpty
        ? 'All ${files.length} hand-written Dart files are formatted.'
        : '${changed.length} of ${files.length} hand-written Dart files are '
              'not formatted. An agent that formats a file it edits adds '
              'unrelated changes to the diff.',
    evidence: [
      'Checked with `${dart == 'dart' ? 'dart' : p.relative(dart, from: root)} '
          'format --output=none` (no files written).',
      for (final f in changed.take(10)) 'Not formatted: $f',
      if (unresolved.isNotEmpty)
        'Skipped packages without pub get: ${unresolved.join(', ')}.',
    ],
    fix:
        'Run `dart format` on the listed files in a separate commit, and add '
        '`dart format --set-exit-if-changed` to CI.',
    details: {'changed': changed, 'checked': files.length},
  );
}

bool _hasPackageConfig(String root, String pkgDir) {
  var dir = p.normalize(p.join(root, pkgDir));
  while (true) {
    if (File(p.join(dir, '.dart_tool', 'package_config.json')).existsSync()) {
      return true;
    }
    if (p.equals(dir, root) || p.dirname(dir) == dir) return false;
    dir = p.dirname(dir);
  }
}

ReadinessCheck _formatUnknown(String why) => ReadinessCheck(
  id: 'format',
  area: 'dx',
  status: CheckStatus.unknown,
  summary: why,
);

class _Cmd {
  _Cmd(this.task, this.key, this.line, this.source);
  final String task;

  /// `dart analyze`, `flutter test`, or a script path for commands that a
  /// script runs.
  final String key;
  final String line;
  final String source;
}

final _scriptNameTasks = {
  'test': RegExp(r'(^|[_-])tests?($|[_-])'),
  'analyze': RegExp(r'(^|[_-])(analy[sz]e|lint)($|[_-])'),
  'format': RegExp(r'(^|[_-])format($|[_-])'),
};

final _scriptRef = RegExp(
  r'(?:\./)?((?:scripts|tool|ci|\.github)/[\w./-]+\.(?:sh|py|dart))',
);

List<_Cmd> _commandsIn(Repo repo, String label, String text, {int depth = 0}) {
  final out = <_Cmd>[];
  final clean = joinContinuations(stripHashComments(text));
  for (final line in clean.split('\n')) {
    taskPatterns.forEach((task, re) {
      final m = re.firstMatch(line);
      if (m == null) return;
      final key = m.group(0)!.replaceFirst(RegExp(r'^fvm\s+'), '').trim();
      out.add(_Cmd(task, key.replaceAll(RegExp(r'\s+'), ' '), line, label));
    });
    if (depth > 0) continue;
    for (final m in _scriptRef.allMatches(line)) {
      final script = m.group(1)!;
      final body = repo.read(script);
      if (body == null) continue;
      final inner = _commandsIn(repo, script, body, depth: 1);
      for (final x in inner) {
        out.add(_Cmd(x.task, script, x.line, label));
      }
      // Scripts often start the tool indirectly (`"${FLUTTER[@]}" test`),
      // so a script named for a task counts as that task.
      final name = p.basenameWithoutExtension(script);
      _scriptNameTasks.forEach((task, re) {
        if (re.hasMatch(name) && !inner.any((x) => x.task == task)) {
          out.add(_Cmd(task, script, line, label));
        }
      });
    }
  }
  return out;
}

ReadinessCheck ciParityCheck(ReadinessContext c) {
  final files = ciFiles(c.repo);
  if (files.isEmpty) {
    return ReadinessCheck(
      id: 'ci-parity',
      area: 'dx',
      status: CheckStatus.fail,
      summary:
          'No CI configuration was found, so nothing checks a change '
          'before it merges.',
      fix:
          'Add a CI workflow that runs the same analyze, test and format '
          'commands the instruction file documents.',
    );
  }
  final ci = [
    for (final f in files) ..._commandsIn(c.repo, f, c.repo.read(f) ?? ''),
  ];
  final local = [
    for (final s in c.localCommandSources)
      if (!files.contains(s.label)) ..._commandsIn(c.repo, s.label, s.text),
  ];

  final missing = <String>[];
  final gaps = <String>[];
  for (final task in const ['analyze', 'test', 'format']) {
    final ciCmds = ci.where((x) => x.task == task).toList();
    final localCmds = local.where((x) => x.task == task).toList();
    if (ciCmds.isEmpty) {
      missing.add(task);
      continue;
    }
    final ciKeys = ciCmds.map((x) => x.key).toSet();
    final localKeys = localCmds.map((x) => x.key).toSet();
    if (localKeys.isNotEmpty && ciKeys.intersection(localKeys).isEmpty) {
      gaps.add(
        '$task: CI runs ${ciKeys.map((k) => '`$k`').join(', ')}, but the '
        'docs give ${localKeys.map((k) => '`$k`').join(', ')}.',
      );
    }
    if (task == 'analyze' &&
        ciCmds.any((x) => x.line.contains('--fatal-infos')) &&
        localCmds.isNotEmpty &&
        !localCmds.any((x) => x.line.contains('--fatal-infos'))) {
      gaps.add(
        'analyze: CI fails on infos (`--fatal-infos`), but the documented '
        'command does not, so a change that passes locally can fail in CI.',
      );
    }
  }

  final status = missing.isEmpty && gaps.isEmpty
      ? CheckStatus.pass
      : CheckStatus.warn;
  return ReadinessCheck(
    id: 'ci-parity',
    area: 'dx',
    status: status,
    summary: status == CheckStatus.pass
        ? 'CI runs analyze, test and format, with the same commands the docs give.'
        : [
            if (missing.isNotEmpty) 'CI does not run: ${missing.join(', ')}.',
            if (gaps.isNotEmpty) 'CI and the documented commands differ.',
          ].join(' '),
    evidence: [
      'CI files: ${files.join(', ')}.',
      for (final task in const ['analyze', 'test', 'format'])
        if (ci.where((x) => x.task == task).isNotEmpty)
          '$task in CI: ${ci.where((x) => x.task == task).map((x) => x.key).toSet().join(', ')}',
      ...gaps,
    ],
    fix:
        'Make CI and the instruction file use the same command for each '
        'task (one script or Makefile target that both call), and add any '
        'missing step to CI.',
  );
}

ReadinessCheck setupDocsCheck(ReadinessContext c) {
  final repo = c.repo;
  final readme = repo.files
      .where(
        (f) => RegExp(r'^readme(\.md)?$', caseSensitive: false).hasMatch(f),
      )
      .firstOrNull;
  if (readme == null) {
    return ReadinessCheck(
      id: 'setup-docs',
      area: 'dx',
      status: CheckStatus.fail,
      summary: 'The project has no README.',
      fix:
          'Add a README with setup steps, environment configuration, the '
          'architecture, and the release process.',
    );
  }
  final docFiles = [
    readme,
    for (final f in repo.files)
      if (RegExp(r'^docs/[^/]+\.md$').hasMatch(f)) f,
    ...c.docs.map((d) => d.path),
  ];
  final texts = {for (final f in docFiles) f: repo.read(f) ?? ''};

  String? where(RegExp heading, {RegExp? fileName, RegExp? text}) {
    for (final e in texts.entries) {
      if (heading.hasMatch(e.value)) return e.key;
      if (fileName != null && fileName.hasMatch(p.basename(e.key))) {
        return e.key;
      }
      if (text != null && text.hasMatch(e.value)) return e.key;
    }
    return null;
  }

  RegExp h(String words) =>
      RegExp('^#+\\s.*\\b($words)', caseSensitive: false, multiLine: true);

  final found = {
    'setup': where(
      h(
        'getting started|set ?up|install|prerequisites|requirements|'
        'quick ?start|how to run|running|local development|development',
      ),
    ),
    'environment': where(
      h('environment|env\\b|configuration|config|secrets|flavou?rs?'),
      text: RegExp(r'\.env\b|--dart-define'),
    ),
    'architecture': where(
      h('architecture|structure|overview|design'),
      fileName: RegExp('architecture', caseSensitive: false),
    ),
    'release': where(
      h('release|deploy|publish|distribution|shipping'),
      fileName: RegExp('release|deploy', caseSensitive: false),
    ),
  };

  final pubspecs = [
    for (final pkg in c.packages)
      if (!pkg.vendored) repo.read(p.join(pkg.dir, 'pubspec.yaml')) ?? '',
  ];
  final pin = [
    '.fvmrc',
    '.fvm/fvm_config.json',
    '.tool-versions',
    'mise.toml',
    '.mise.toml',
    '.puro.json',
  ].where((f) => repo.isVisible(f) || repo.existsOnDisk(f)).toList();
  if (pubspecs.any(
    RegExp(
      r'^environment:[^\n]*\n(?:[ \t]+[^\n]*\n)*?[ \t]+flutter:',
      multiLine: true,
    ).hasMatch,
  )) {
    pin.add('pubspec.yaml environment.flutter');
  }

  final usesEnv =
      c.packages.any(
        (p) =>
            !p.vendored &&
            (p.dependsOn('flutter_dotenv') ||
                p.dependsOn('envied') ||
                p.dependsOn('dotenv') ||
                p.dependsOn('flutter_config')),
      ) ||
      pubspecs.any(RegExp(r'^\s*-\s*\.env', multiLine: true).hasMatch);
  final envTemplate = repo.files
      .where(
        (f) => RegExp(
          r'(^|/)\.?env(\.[\w-]+)?\.(example|sample|template|dist)$',
        ).hasMatch(f),
      )
      .firstOrNull;

  final usesFlutter = c.packages.any(
    (pkg) => !pkg.vendored && pkg.dependsOn('flutter'),
  );
  final missing = [
    for (final e in found.entries)
      // Environment docs matter for apps and code that reads env files.
      if (e.value == null && (e.key != 'environment' || usesFlutter || usesEnv))
        '${e.key} docs',
    if (pin.isEmpty && usesFlutter) 'a pinned Flutter version',
    if (usesEnv && envTemplate == null) 'an env template (.env.example)',
  ];
  return ReadinessCheck(
    id: 'setup-docs',
    area: 'dx',
    status: missing.isEmpty ? CheckStatus.pass : CheckStatus.warn,
    summary: missing.isEmpty
        ? 'Setup, environment, architecture and release are documented, and '
              'the Flutter version is pinned.'
        : 'Missing: ${missing.join(', ')}.',
    evidence: [
      for (final e in found.entries) '${e.key}: ${e.value ?? 'not found'}',
      'Flutter version pin: ${pin.isEmpty ? 'none' : pin.join(', ')}.',
      if (usesEnv)
        'The app reads a .env file; template: ${envTemplate ?? 'none'}.',
    ],
    fix:
        'Document the missing parts. Commit a `.env.example` with every key '
        'and fake values, and pin the Flutter version with FVM (`.fvmrc`).',
  );
}
