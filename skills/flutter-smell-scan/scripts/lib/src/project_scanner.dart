/// Walks a Flutter/Dart project, runs the file scanner on every source file,
/// optionally runs `dart analyze`, and builds the JSON report.
///
/// Read-only on the target: it never runs `pub get` and never writes inside
/// the scanned directory.
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

import 'file_scanner.dart';
import 'model.dart';

const toolVersion = '0.1.0';

/// Directories never scanned, at any depth. Dot-directories are skipped too.
const _skipDirs = {'build', 'node_modules', 'Pods'};

/// Platform folders, skipped only directly under a package root (a
/// directory with pubspec.yaml), so `lib/features/web/` is still scanned.
const _platformDirs = {'ios', 'android', 'macos', 'linux', 'windows', 'web'};

/// Test directories, scanned only with --include-tests.
const _testDirs = {'test', 'integration_test', 'test_driver'};

final _generatedSuffixes = [
  '.g.dart',
  '.freezed.dart',
  '.gr.dart',
  '.config.dart',
  '.mocks.dart',
  '.pb.dart',
  '.pbenum.dart',
  '.pbjson.dart',
  '.pbserver.dart',
  '.gen.dart',
  '.chopper.dart',
];

class ScanOptions {
  ScanOptions({
    required this.root,
    this.includeTests = false,
    this.runAnalyzer = true,
    this.top = 15,
    Thresholds? thresholds,
  }) : thresholds = thresholds ?? Thresholds();

  final String root;
  final bool includeTests;
  final bool runAnalyzer;
  final int top;
  final Thresholds thresholds;
}

class ScanResult {
  ScanResult(this.json);
  final Map<String, Object?> json;
}

Future<ScanResult> scanProject(ScanOptions o) async {
  final root = p.normalize(p.absolute(o.root));
  final files = _collectFiles(root, o.includeTests);
  final packages = _findPackages(root);

  final reports = <FileReport>[];
  var generatedSkipped = 0;
  for (final file in files) {
    final rel = p.relative(file, from: root);
    if (_generatedSuffixes.any(rel.endsWith)) {
      generatedSkipped++;
      continue;
    }
    final content = File(file).readAsStringSync();
    if (content.trimLeft().startsWith(
      RegExp(r'//\s*(GENERATED CODE|Generated code|@generated|DO NOT EDIT)'),
    )) {
      generatedSkipped++;
      continue;
    }
    final parsed = parseString(
      content: content,
      path: file,
      featureSet: FeatureSet.latestLanguageVersion(),
      throwIfDiagnostics: false,
    );
    final report = FileScanner(
      path: rel,
      unit: parsed.unit,
      content: content,
      t: o.thresholds,
    ).scan();
    report.parseErrors = parsed.errors.isNotEmpty;
    reports.add(report);
  }

  final findings = [for (final r in reports) ...r.findings];
  findings.addAll(_projectFindings(reports));
  findings.sort((a, b) {
    final s = a.severity.index.compareTo(b.severity.index);
    if (s != 0) return s;
    final f = a.file.compareTo(b.file);
    return f != 0 ? f : a.line.compareTo(b.line);
  });

  final bySmell = <String, Map<String, int>>{};
  for (final f in findings) {
    final entry = bySmell.putIfAbsent(
      f.smell,
      () => {'high': 0, 'medium': 0, 'low': 0},
    );
    entry[f.severity.name] = entry[f.severity.name]! + 1;
  }

  final hotspots = [...reports]..sort((a, b) => b.score.compareTo(a.score));

  final analyzer = o.runAnalyzer
      ? await _runDartAnalyze(root, packages)
      : <String, Object?>{'status': 'skipped', 'reason': '--no-analyze'};

  return ScanResult({
    'tool': 'flutter-smell-scan',
    'version': toolVersion,
    'root': root,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'options': {
      'includeTests': o.includeTests,
      'thresholds': o.thresholds.values,
    },
    'summary': {
      'filesScanned': reports.length,
      'generatedFilesSkipped': generatedSkipped,
      'totalLines': reports.fold<int>(0, (s, r) => s + r.lines),
      'filesWithParseErrors': [
        for (final r in reports)
          if (r.parseErrors) r.path,
      ],
      'findings': findings.length,
      'bySeverity': {
        for (final s in Severity.values)
          s.name: findings.where((f) => f.severity == s).length,
      },
      'bySmell': bySmell,
    },
    'packages': packages.map((k, v) => MapEntry(k, {'resolved': v})),
    'stateManagement': _stateSignals(reports),
    'hotspots': [
      for (final r in hotspots.take(o.top))
        if (r.score > 0)
          {
            'file': r.path,
            'score': r.score,
            'lines': r.lines,
            'findings': r.findings.length,
            'smells': {
              for (final s in {for (final f in r.findings) f.smell})
                s: r.findings.where((f) => f.smell == s).length,
            },
          },
    ],
    'findings': [for (final f in findings) f.toJson()],
    'todos': [
      for (final r in reports)
        for (final t in r.todos) {'file': r.path, ...t.toJson()},
    ].take(100).toList(),
    'analyzer': analyzer,
  });
}

List<String> _collectFiles(String root, bool includeTests) {
  final out = <String>[];
  void walk(Directory dir) {
    final entries = dir.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    final isPackageRoot = File(p.join(dir.path, 'pubspec.yaml')).existsSync();
    for (final e in entries) {
      final name = p.basename(e.path);
      if (e is Directory) {
        if (name.startsWith('.') || _skipDirs.contains(name)) continue;
        if (isPackageRoot && _platformDirs.contains(name)) continue;
        if (!includeTests && _testDirs.contains(name)) continue;
        walk(e);
      } else if (e is File && name.endsWith('.dart')) {
        out.add(e.path);
      }
    }
  }

  walk(Directory(root));
  return out;
}

/// Every directory with a pubspec.yaml, mapped to whether `pub get` has run
/// (a package_config.json exists in it or in a workspace ancestor).
Map<String, bool> _findPackages(String root) {
  final result = <String, bool>{};
  void walk(Directory dir) {
    final isPackageRoot = File(p.join(dir.path, 'pubspec.yaml')).existsSync();
    if (isPackageRoot) {
      result[p.relative(dir.path, from: root)] = _hasPackageConfig(
        dir.path,
        root,
      );
    }
    for (final e in dir.listSync(followLinks: false)) {
      final name = p.basename(e.path);
      if (e is Directory &&
          !name.startsWith('.') &&
          !_skipDirs.contains(name) &&
          !(isPackageRoot && _platformDirs.contains(name))) {
        walk(e);
      }
    }
  }

  walk(Directory(root));
  return result;
}

bool _hasPackageConfig(String dir, String root) {
  if (File(p.join(dir, '.dart_tool', 'package_config.json')).existsSync()) {
    return true;
  }
  // Only pub workspace members are resolved by an ancestor's package config.
  final pubspec = File(p.join(dir, 'pubspec.yaml')).readAsStringSync();
  if (!RegExp(
    r'^resolution:\s*workspace\s*$',
    multiLine: true,
  ).hasMatch(pubspec)) {
    return false;
  }
  var current = dir;
  while (true) {
    if (File(
      p.join(current, '.dart_tool', 'package_config.json'),
    ).existsSync()) {
      return true;
    }
    if (p.equals(current, root) || p.dirname(current) == current) return false;
    current = p.dirname(current);
  }
}

/// The innermost package (relative path, `.` for the root) containing [rel].
String? _owningPackage(String rel, Iterable<String> packages) {
  String? best;
  for (final pkg in packages) {
    final contains = pkg == '.' || p.isWithin(pkg, rel);
    if (contains && (best == null || pkg.length > best.length || best == '.')) {
      best = pkg;
    }
  }
  return best;
}

List<Finding> _projectFindings(List<FileReport> reports) {
  final families = <String, List<String>>{};
  for (final r in reports) {
    for (final f in r.stateFamilies) {
      families.putIfAbsent(f, () => []).add(r.path);
    }
  }
  if (families.length < 2) return const [];
  final desc = families.entries
      .map((e) => '${e.key} (${e.value.length} files)')
      .join(', ');
  return [
    Finding(
      smell: 'mixed-state-management',
      severity: Severity.medium,
      file: '(project)',
      line: 0,
      value: families.length,
      message:
          'The project imports ${families.length} state-management libraries: '
          '$desc. See stateManagement.families for the file lists.',
    ),
  ];
}

Map<String, Object?> _stateSignals(List<FileReport> reports) {
  final families = <String, List<String>>{};
  for (final r in reports) {
    for (final f in r.stateFamilies) {
      families.putIfAbsent(f, () => []).add(r.path);
    }
  }
  return {
    'families': families,
    'stateClassesUsingSetState': reports.fold<int>(
      0,
      (s, r) => s + r.setStateClasses,
    ),
    'changeNotifierClasses': reports.fold<int>(
      0,
      (s, r) => s + r.changeNotifierClasses,
    ),
  };
}

Future<Map<String, Object?>> _runDartAnalyze(
  String root,
  Map<String, bool> packages,
) async {
  final unresolved = [
    for (final e in packages.entries)
      if (!e.value) e.key,
  ];
  if (packages.isNotEmpty && unresolved.length == packages.length) {
    return {
      'status': 'skipped',
      'reason':
          'No package has a .dart_tool/package_config.json, so the analyzer '
          'cannot resolve imports or load lint rules. Its output would be '
          'unresolved-import noise. Run `flutter pub get` in the project '
          '(with the user\'s OK) and scan again to include analyzer results.',
      'unresolvedPackages': unresolved,
    };
  }

  final ProcessResult result;
  try {
    result = await Process.run('dart', [
      'analyze',
      '--format=json',
      '--no-fatal-warnings',
      root,
    ]);
  } on ProcessException catch (e) {
    return {'status': 'failed', 'reason': 'Could not start dart: ${e.message}'};
  }

  final out = result.stdout as String;
  final start = out.indexOf('{');
  if (start < 0) {
    return {
      'status': 'failed',
      'reason': 'dart analyze printed no JSON.',
      'exitCode': result.exitCode,
      'stderr': (result.stderr as String).trim(),
    };
  }

  final Map<String, dynamic> decoded;
  try {
    decoded = jsonDecode(out.substring(start)) as Map<String, dynamic>;
  } on FormatException catch (e) {
    return {'status': 'failed', 'reason': 'Bad JSON: ${e.message}'};
  }

  final diagnostics = <Map<String, Object?>>[];
  var droppedUnresolved = 0;
  for (final d in (decoded['diagnostics'] as List? ?? const [])) {
    final m = d as Map<String, dynamic>;
    final loc = m['location'] as Map<String, dynamic>? ?? const {};
    final file = loc['file'] as String? ?? '';
    final rel = p.relative(file, from: root);
    final owner = _owningPackage(rel, packages.keys);
    if (owner != null && packages[owner] == false) {
      droppedUnresolved++;
      continue;
    }
    final range = loc['range'] as Map<String, dynamic>? ?? const {};
    final startPos = range['start'] as Map<String, dynamic>? ?? const {};
    diagnostics.add({
      'file': rel,
      'line': startPos['line'],
      'severity': m['severity'],
      'type': m['type'],
      'code': m['code'],
      'message': m['problemMessage'],
    });
  }

  final byCode = <String, int>{};
  for (final d in diagnostics) {
    final code = '${d['code']}';
    byCode[code] = (byCode[code] ?? 0) + 1;
  }
  final sortedCodes = byCode.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  return {
    'status': 'ok',
    'exitCode': result.exitCode,
    'unresolvedPackages': unresolved,
    'droppedFromUnresolvedPackages': droppedUnresolved,
    'total': diagnostics.length,
    'byCode': {for (final e in sortedCodes) e.key: e.value},
    'diagnostics': diagnostics.take(500).toList(),
  };
}
