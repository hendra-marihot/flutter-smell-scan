/// Checks built on the import graph and the git history: tests an agent can
/// find, files nothing uses, and files that change together without a
/// visible link.
library;

import 'package:path/path.dart' as p;

import '../file_scanner.dart';
import 'history.dart';
import 'import_graph.dart';
import 'model.dart';

/// Below this share of files with a findable test, an agent that changes a
/// file usually has no test to run for it. A convention, not a measured
/// cut-off.
const _minTestedShare = 0.5;

/// A first-party package this large with no test file at all is a gap even
/// when the rest of the project is well tested.
const _untestedPackageFiles = 10;

/// Co-change needs this many commits to say anything.
const _minHistoryCommits = 20;

/// A pair must change together in this many commits...
const _minSharedCommits = 5;

/// ...and in at least this share of the commits that change either file
/// (shared commits divided by the average of the two files' commit counts,
/// as in Code Maat).
const _minCoupling = 0.5;

Map<String, FileReport> _reportsByPath(ReadinessContext c) => {
  for (final r in c.reports) r.path: r,
};

ReadinessCheck testMappingCheck(
  ReadinessContext c,
  ImportGraph graph,
  History history,
) {
  final reports = _reportsByPath(c);
  // Files with code worth testing: a class, mixin or function. Parts are
  // tested through their library.
  final libFiles = [
    for (final n in graph.ownLibFiles)
      if (!n.links.isPart &&
          reports[n.path] != null &&
          reports[n.path]!.classes + reports[n.path]!.functions > 0)
        n,
  ];
  if (libFiles.isEmpty) {
    return ReadinessCheck(
      id: 'test-mapping',
      area: 'ax',
      status: CheckStatus.unknown,
      summary: 'No first-party lib/ file declares a class or function.',
    );
  }

  final testsByPackage = <String, List<GraphNode>>{};
  for (final n in graph.nodes.values) {
    if (n.isTest && !n.package!.vendored) {
      testsByPackage.putIfAbsent(n.package!.dir, () => []).add(n);
    }
  }

  final perPackage = <String, Map<String, int>>{};
  final untested = <GraphNode>[];
  var byName = 0;
  var byImportOnly = 0;
  for (final n in libFiles) {
    final dir = n.package!.dir;
    final tests = testsByPackage[dir] ?? const [];
    final stats = perPackage.putIfAbsent(
      dir,
      () => {'libFiles': 0, 'tested': 0, 'testFiles': tests.length},
    );
    stats['libFiles'] = stats['libFiles']! + 1;
    final base = p.posix.basenameWithoutExtension(n.path);
    final named = tests.any(
      (t) => p.posix.basename(t.path) == '${base}_test.dart',
    );
    // Only test files count, not helpers or generated mocks under test/.
    final importedBy = [
      for (final from in graph.importers[n.path] ?? const <String>{})
        if (graph.nodes[from]!.isTest && from.endsWith('_test.dart')) from,
    ];
    final imported = importedBy.isNotEmpty;
    if (named) byName++;
    if (!named && imported) byImportOnly++;
    if (named || imported) {
      stats['tested'] = stats['tested']! + 1;
    } else {
      untested.add(n);
    }
  }

  final tested = byName + byImportOnly;
  final share = tested / libFiles.length;
  final totalTests = perPackage.values.fold<int>(
    0,
    (s, x) => s + x['testFiles']!,
  );
  final bigUntested = [
    for (final e in perPackage.entries)
      if (e.value['testFiles'] == 0 &&
          e.value['libFiles']! >= _untestedPackageFiles)
        e.key,
  ];

  // The files an agent changes most are where a missing test costs most.
  int lines(GraphNode n) => reports[n.path]?.lines ?? 0;
  untested.sort((a, b) {
    final h = (history.changes[b.path] ?? 0).compareTo(
      history.changes[a.path] ?? 0,
    );
    return h != 0 ? h : lines(b).compareTo(lines(a));
  });

  final pct = (share * 100).round();
  final CheckStatus status;
  final String summary;
  if (totalTests == 0) {
    status = CheckStatus.fail;
    summary =
        'No test file exists for ${libFiles.length} lib/ files with code.';
  } else if (share < _minTestedShare || bigUntested.isNotEmpty) {
    status = CheckStatus.warn;
    summary = [
      '$tested of ${libFiles.length} lib/ files ($pct%) have a test that '
          'imports them or is named after them',
      if (bigUntested.isNotEmpty)
        '${bigUntested.length} package(s) with $_untestedPackageFiles+ '
            'files have no test',
    ].join('; ');
  } else {
    status = CheckStatus.pass;
    summary =
        '$tested of ${libFiles.length} lib/ files ($pct%) have a test that '
        'imports them or is named after them.';
  }

  return ReadinessCheck(
    id: 'test-mapping',
    area: 'ax',
    status: status,
    summary: status == CheckStatus.warn ? '$summary.' : summary,
    evidence: [
      '$byName file(s) have a test named after them '
          '(`foo.dart` and `foo_test.dart`); $byImportOnly more are '
          'imported directly by a test.',
      for (final d in bigUntested)
        '`$d` has ${perPackage[d]!['libFiles']} lib/ files and no test.',
      if (untested.isNotEmpty)
        'Untested, ${history.commits.isEmpty ? 'largest' : 'most changed'} '
            'first: ${untested.take(5).map((n) => '`${n.path}`').join(', ')}.',
    ],
    fix:
        'Add tests for the most-changed files first, and name each test '
        'after its file (`lib/a/foo.dart` and `test/a/foo_test.dart`), so an '
        'agent that changes a file can find and run its test.',
    details: {
      'libFiles': libFiles.length,
      'tested': tested,
      'testedByName': byName,
      'testedByImportOnly': byImportOnly,
      'packages': perPackage,
      'untested': [
        for (final n in untested.take(30))
          {
            'file': n.path,
            'lines': lines(n),
            if (history.commits.isNotEmpty)
              'commits': history.changes[n.path] ?? 0,
          },
      ],
    },
  );
}

ReadinessCheck unusedFilesCheck(ReadinessContext c, ImportGraph graph) {
  final reports = _reportsByPath(c);
  final own = graph.ownLibFiles.toList();
  if (own.isEmpty) {
    return ReadinessCheck(
      id: 'unused-files',
      area: 'ax',
      status: CheckStatus.unknown,
      summary: 'No first-party lib/ files were found.',
    );
  }
  final production = graph.reachableFrom(graph.productionRoots);
  final all = graph.reachableFrom({
    ...graph.productionRoots,
    ...graph.testRoots,
  });
  int lines(String f) => reports[f]?.lines ?? 0;
  final unused = [
    for (final n in own)
      if (!all.contains(n.path)) n.path,
  ]..sort((a, b) => lines(b).compareTo(lines(a)));
  final testOnly = [
    for (final n in own)
      if (all.contains(n.path) && !production.contains(n.path)) n.path,
  ]..sort();
  final unusedLines = unused.fold<int>(0, (s, f) => s + lines(f));

  final fallback = graph.missingGenerated.isNotEmpty;
  return ReadinessCheck(
    id: 'unused-files',
    area: 'ax',
    status: unused.isEmpty ? CheckStatus.pass : CheckStatus.warn,
    summary: unused.isEmpty
        ? 'Every lib/ file is reached by an import from an entry point or a '
              'test.'
        : '${unused.length} lib/ file(s) ($unusedLines lines) are not '
              'imported from any entry point or test.',
    evidence: [
      for (final f in unused.take(10)) '`$f` (${lines(f)} lines)',
      if (testOnly.isNotEmpty)
        '${testOnly.length} lib/ file(s) are imported only by tests.',
      if (fallback)
        '${graph.missingGenerated.length} imported generated file(s) are not '
            'on disk (for example `${graph.missingGenerated.first}`), so '
            'classes annotated for injectable or auto_route count as used.',
    ],
    fix:
        'Delete the unused files, or import them where they are meant to be '
        'used. An agent that searches the code finds dead files, reads them, '
        'and may copy or edit them.',
    details: {
      'libFiles': own.length,
      'entryPoints': graph.productionRoots
          .where((f) => graph.nodes[f]!.inLib)
          .length,
      'unused': unused.take(50).toList(),
      'testOnly': testOnly.take(20).toList(),
      if (fallback)
        'missingGenerated': graph.missingGenerated.take(10).toList(),
    },
  );
}

ReadinessCheck coChangeCheck(
  ReadinessContext c,
  ImportGraph graph,
  History history,
) {
  if (history.error != null) {
    return ReadinessCheck(
      id: 'co-change',
      area: 'ax',
      status: CheckStatus.unknown,
      summary: 'No git history to read: ${history.error}.',
    );
  }
  final keep = {for (final n in graph.ownLibFiles) n.path};
  final changes = <String, int>{};
  final shared = <(String, String), int>{};
  var used = 0;
  var skipped = 0;
  for (final commit in history.commits) {
    final files = {
      for (final f in commit)
        if (keep.contains(f)) f,
    }.toList()..sort();
    if (files.isEmpty) continue;
    if (files.length > maxFilesPerCommit) {
      skipped++;
      continue;
    }
    used++;
    for (final f in files) {
      changes[f] = (changes[f] ?? 0) + 1;
    }
    for (var i = 0; i < files.length; i++) {
      for (var j = i + 1; j < files.length; j++) {
        final key = (files[i], files[j]);
        shared[key] = (shared[key] ?? 0) + 1;
      }
    }
  }
  if (used < _minHistoryCommits) {
    return ReadinessCheck(
      id: 'co-change',
      area: 'ax',
      status: CheckStatus.unknown,
      summary:
          'Only $used commit(s) change lib/ files, too few to find files '
          'that change together.',
      details: {'commits': used, 'skippedLargeCommits': skipped},
    );
  }

  final pairs = <Map<String, Object?>>[];
  var linkedPairs = 0;
  shared.forEach((key, count) {
    if (count < _minSharedCommits) return;
    final (a, b) = key;
    final coupling = count / ((changes[a]! + changes[b]!) / 2);
    if (coupling < _minCoupling) return;
    if (graph.linked(a, b)) {
      linkedPairs++;
      return;
    }
    pairs.add({
      'files': [a, b],
      'sharedCommits': count,
      'coupling': double.parse(coupling.toStringAsFixed(2)),
      'sameDirectory': p.posix.dirname(a) == p.posix.dirname(b),
      'importedTogetherBy': graph.commonImporters(a, b).take(3).toList(),
    });
  });
  pairs.sort((x, y) {
    final s = (y['sharedCommits']! as int).compareTo(
      x['sharedCommits']! as int,
    );
    return s != 0
        ? s
        : (y['coupling']! as double).compareTo(x['coupling']! as double);
  });

  String show(Map<String, Object?> pair) {
    final files = pair['files']! as List<String>;
    return '`${files[0]}` and `${files[1]}`: ${pair['sharedCommits']} '
        'commits together (${((pair['coupling']! as double) * 100).round()}%)';
  }

  return ReadinessCheck(
    id: 'co-change',
    area: 'ax',
    status: pairs.isEmpty ? CheckStatus.pass : CheckStatus.warn,
    summary: pairs.isEmpty
        ? 'Files that often change together also import each other '
              '($used commits read).'
        : '${pairs.length} pair(s) of files often change together but '
              'neither imports the other ($used commits read).',
    evidence: [for (final x in pairs.take(5)) show(x)],
    fix:
        'For each pair, find what they share (a duplicated widget, a copied '
        'constant, a protocol both sides implement). Move it into one place '
        'that both import, or, when the link must stay, write it down in '
        'the instruction file. An agent that changes one file cannot see '
        'that the other must change too.',
    details: {
      'commits': used,
      'skippedLargeCommits': skipped,
      'linkedPairs': linkedPairs,
      'hiddenPairs': pairs.take(20).toList(),
    },
  );
}
