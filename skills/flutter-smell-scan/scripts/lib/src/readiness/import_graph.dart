/// The import graph of the project's Dart files, built from directives only.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

import '../dart_files.dart';
import '../file_scanner.dart';
import 'repo.dart';

/// Annotations that register a class with a code generator (injectable,
/// auto_route). The generated file that imports such a class is the only
/// link to it, so when that file is missing the class counts as used.
const registrationAnnotations = {
  'injectable',
  'Injectable',
  'singleton',
  'Singleton',
  'lazySingleton',
  'LazySingleton',
  'module',
  'RoutePage',
};

class GraphNode {
  GraphNode(this.path, this.links, {required this.generated, this.package});

  /// Relative to the scan root, with `/` separators.
  final String path;
  final DartLinks links;
  final bool generated;
  final LocalPackage? package;

  late final String _inPackage = package == null || package!.dir == '.'
      ? path
      : p.posix.relative(path, from: package!.dir);

  /// True for files under the package's `lib/`.
  bool get inLib => package != null && _inPackage.startsWith('lib/');

  /// True for files under the package's `lib/src/`.
  bool get inLibSrc => package != null && _inPackage.startsWith('lib/src/');

  /// True for files under the package's test directories.
  bool get isTest =>
      package != null && testDirs.contains(_inPackage.split('/').first);
}

class ImportGraph {
  ImportGraph._(this.nodes, this.edges, this.exports, this.missingGenerated);

  final Map<String, GraphNode> nodes;

  /// Import, export and part edges, from a file to the files it names.
  final Map<String, Set<String>> edges;

  /// Export edges only, a subset of [edges].
  final Map<String, Set<String>> exports;

  /// Generated files that are imported but not on disk (usually because
  /// they are gitignored and the build has not run).
  final Set<String> missingGenerated;

  /// Reverse of [edges].
  late final Map<String, Set<String>> importers = () {
    final out = <String, Set<String>>{};
    edges.forEach((from, tos) {
      for (final to in tos) {
        out.putIfAbsent(to, () => {}).add(from);
      }
    });
    return out;
  }();

  final _visible = <String, Set<String>>{};

  /// The files whose names [from] can use: the files it imports, exports
  /// or includes, plus everything those files re-export, at any depth.
  Set<String> visibleFrom(String from) => _visible.putIfAbsent(from, () {
    final seen = <String>{};
    final queue = [...?edges[from]];
    while (queue.isNotEmpty) {
      final next = queue.removeLast();
      if (seen.add(next)) queue.addAll(exports[next] ?? const <String>{});
    }
    return seen;
  });

  /// True when [a] can see [b] or [b] can see [a] through its directives,
  /// including re-exports from a barrel file.
  bool linked(String a, String b) =>
      visibleFrom(a).contains(b) || visibleFrom(b).contains(a);

  /// Hand-written files outside tests that import both [a] and [b], sorted.
  List<String> commonImporters(String a, String b) {
    final both = (importers[a] ?? const <String>{}).intersection(
      importers[b] ?? const <String>{},
    );
    return [
      for (final f in both)
        if (!nodes[f]!.generated && !nodes[f]!.isTest) f,
    ]..sort();
  }

  /// First-party, hand-written files under `lib/`.
  Iterable<GraphNode> get ownLibFiles => nodes.values.where(
    (n) => n.inLib && !n.generated && !n.package!.vendored,
  );

  static ImportGraph build({
    required String root,
    required List<LocalPackage> packages,
    required List<FileReport> reports,
  }) {
    final byPath = {for (final r in reports) r.path: r};
    final nodes = <String, GraphNode>{};
    for (final abs in collectDartFiles(root, includeTests: true)) {
      final rel = p.relative(abs, from: root).replaceAll(r'\', '/');
      final report = byPath[rel];
      final DartLinks links;
      final bool generated;
      if (report != null) {
        links = report.links;
        generated = false;
      } else {
        final String content;
        try {
          content = File(abs).readAsStringSync();
        } on FileSystemException {
          continue;
        }
        links = linksOf(
          parseString(
            content: content,
            path: abs,
            featureSet: FeatureSet.latestLanguageVersion(),
            throwIfDiagnostics: false,
          ).unit,
        );
        generated = hasGeneratedSuffix(rel) || hasGeneratedHeader(content);
      }
      nodes[rel] = GraphNode(
        rel,
        links,
        generated: generated,
        package: owningPackage(rel, packages),
      );
    }

    final byName = <String, LocalPackage>{};
    for (final pkg in packages) {
      final name = pkg.name;
      if (name == null) continue;
      // A first-party package wins over a vendored copy with the same name.
      if (!byName.containsKey(name) || byName[name]!.vendored) {
        byName[name] = pkg;
      }
    }

    String? resolve(String from, String uri) {
      if (uri.startsWith('dart:')) return null;
      if (uri.startsWith('package:')) {
        final rest = uri.substring('package:'.length);
        final slash = rest.indexOf('/');
        if (slash < 0) return null;
        final pkg = byName[rest.substring(0, slash)];
        if (pkg == null) return null;
        return p.posix.normalize(
          p.posix.join(pkg.dir, 'lib', rest.substring(slash + 1)),
        );
      }
      if (uri.contains(':')) return null;
      final target = p.posix.normalize(
        p.posix.join(p.posix.dirname(from), uri),
      );
      return target.startsWith('../') ? null : target;
    }

    final edges = <String, Set<String>>{};
    final exports = <String, Set<String>>{};
    final missingGenerated = <String>{};
    for (final n in nodes.values) {
      final out = edges[n.path] = <String>{};
      for (final uri in n.links.uris) {
        final target = resolve(n.path, uri);
        if (target == null) continue;
        if (nodes.containsKey(target)) {
          out.add(target);
        } else if (hasGeneratedSuffix(target)) {
          missingGenerated.add(target);
        }
      }
      final exported = exports[n.path] = <String>{};
      for (final uri in n.links.exportUris) {
        final target = resolve(n.path, uri);
        if (target != null && nodes.containsKey(target)) exported.add(target);
      }
      for (final uri in n.links.partUris) {
        final target = resolve(n.path, uri);
        if (target != null && nodes.containsKey(target)) out.add(target);
      }
    }
    return ImportGraph._(nodes, edges, exports, missingGenerated);
  }

  /// Entry points that run the app or its tools: every file outside `lib/`
  /// that is not a test, every `lib/` file with a top-level `main`, and
  /// the public files (outside `lib/src/`) of packages without a `main`.
  late final Set<String> productionRoots = () {
    final appPackages = {
      for (final n in nodes.values)
        if (n.inLib && n.links.hasMain) n.package!.dir,
    };
    final fallback = missingGenerated.isNotEmpty;
    return {
      for (final n in nodes.values)
        if (!n.isTest &&
            (!n.inLib ||
                n.links.hasMain ||
                (!appPackages.contains(n.package!.dir) && !n.inLibSrc) ||
                (fallback &&
                    n.links.annotations.any(registrationAnnotations.contains))))
          n.path,
    };
  }();

  late final Set<String> testRoots = {
    for (final n in nodes.values)
      if (n.isTest) n.path,
  };

  Set<String> reachableFrom(Iterable<String> roots) {
    final seen = <String>{...roots};
    final queue = [...roots];
    while (queue.isNotEmpty) {
      final next = queue.removeLast();
      for (final to in edges[next] ?? const <String>{}) {
        if (seen.add(to)) queue.add(to);
      }
    }
    return seen;
  }
}
