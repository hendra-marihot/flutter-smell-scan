/// Finds the Dart files of a project and reads the links between them.
library;

import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

/// Directories never scanned, at any depth. Dot-directories are skipped too.
const skipDirs = {'build', 'node_modules', 'Pods'};

/// Platform folders, skipped only directly under a package root (a
/// directory with pubspec.yaml), so `lib/features/web/` is still scanned.
const platformDirs = {'ios', 'android', 'macos', 'linux', 'windows', 'web'};

/// Test directories, scanned only with --include-tests.
const testDirs = {'test', 'integration_test', 'test_driver'};

const generatedSuffixes = [
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

final _generatedHeader = RegExp(
  r'//\s*(GENERATED CODE|Generated code|@generated|DO NOT EDIT)',
);

bool hasGeneratedSuffix(String path) => generatedSuffixes.any(path.endsWith);

bool hasGeneratedHeader(String content) =>
    content.trimLeft().startsWith(_generatedHeader);

/// Absolute paths of the Dart files under [root], sorted. Skips hidden
/// directories, `build/`, platform folders next to a pubspec.yaml, and test
/// directories unless [includeTests] is true.
List<String> collectDartFiles(String root, {required bool includeTests}) {
  final out = <String>[];
  void walk(Directory dir) {
    final entries = dir.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    final isPackageRoot = File(p.join(dir.path, 'pubspec.yaml')).existsSync();
    for (final e in entries) {
      final name = p.basename(e.path);
      if (e is Directory) {
        if (name.startsWith('.') || skipDirs.contains(name)) continue;
        if (isPackageRoot && platformDirs.contains(name)) continue;
        if (!includeTests && testDirs.contains(name)) continue;
        walk(e);
      } else if (e is File && name.endsWith('.dart')) {
        out.add(e.path);
      }
    }
  }

  walk(Directory(root));
  return out;
}

/// The links from one Dart file to other files, read from its directives.
class DartLinks {
  DartLinks({
    required this.uris,
    required this.exportUris,
    required this.partUris,
    required this.isPart,
    required this.hasMain,
    required this.annotations,
  });

  /// URIs of `import` and `export` directives, including every
  /// conditional-import alternative.
  final List<String> uris;

  /// The subset of [uris] that `export` directives name.
  final List<String> exportUris;

  /// URIs of `part` directives.
  final List<String> partUris;

  /// True when the file is a `part of` another library.
  final bool isPart;

  /// True when the file declares a top-level `main` function.
  final bool hasMain;

  /// Names of the annotations on top-level declarations, such as
  /// `injectable` or `RoutePage`.
  final Set<String> annotations;
}

DartLinks linksOf(CompilationUnit unit) {
  final uris = <String>[];
  final exportUris = <String>[];
  final partUris = <String>[];
  var isPart = false;
  for (final d in unit.directives) {
    switch (d) {
      case NamespaceDirective():
        final all = [
          ?d.uri.stringValue,
          for (final c in d.configurations) ?c.uri.stringValue,
        ];
        uris.addAll(all);
        if (d is ExportDirective) exportUris.addAll(all);
      case PartDirective():
        if (d.uri.stringValue case final uri?) partUris.add(uri);
      case PartOfDirective():
        isPart = true;
      default:
        break;
    }
  }
  final annotations = <String>{};
  var hasMain = false;
  for (final decl in unit.declarations) {
    if (decl is FunctionDeclaration && decl.name.lexeme == 'main') {
      hasMain = true;
    }
    for (final a in decl.metadata) {
      annotations.add(a.name.name.split('.').last);
    }
  }
  return DartLinks(
    uris: uris,
    exportUris: exportUris,
    partUris: partUris,
    isPart: isPart,
    hasMain: hasMain,
    annotations: annotations,
  );
}
