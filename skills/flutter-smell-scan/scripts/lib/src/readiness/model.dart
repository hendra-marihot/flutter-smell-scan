/// Types for the agent-readiness scorecard.
library;

import '../file_scanner.dart';
import 'repo.dart';

/// `unknown` means the scanner could not decide (for example, an
/// unresolvable lint include). Claude checks it by reading.
enum CheckStatus { pass, warn, fail, unknown }

class ReadinessCheck {
  ReadinessCheck({
    required this.id,
    required this.area,
    required this.status,
    required this.summary,
    this.evidence = const [],
    this.fix,
    this.details,
  });

  /// Check id from references/readiness-checks.md, e.g. `instruction-file`.
  final String id;

  /// `ax` (agent experience) or `dx` (developer experience).
  final String area;
  final CheckStatus status;

  /// One sentence: the result.
  final String summary;

  /// Short facts behind the status, each with a path when there is one.
  final List<String> evidence;

  /// The concrete next step, for warn and fail.
  final String? fix;

  /// Structured data for Claude (file lists, counts).
  final Map<String, Object?>? details;

  Map<String, Object?> toJson() => {
    'id': id,
    'area': area,
    'status': status.name,
    'summary': summary,
    if (evidence.isNotEmpty) 'evidence': evidence,
    if (fix != null && status != CheckStatus.pass) 'fix': fix,
    if (details != null) 'details': details,
  };
}

/// One instruction file (CLAUDE.md, AGENTS.md, ...) or a file it imports.
class InstructionDoc {
  InstructionDoc(this.path, this.text, {this.importedBy});

  final String path;
  final String text;
  final String? importedBy;

  int get lines => '\n'.allMatches(text).length + 1;
}

/// A text that documents or runs commands, with a label for the evidence.
class CommandSource {
  CommandSource(this.label, this.text);
  final String label;
  final String text;
}

class ReadinessContext {
  ReadinessContext({
    required this.repo,
    required this.packages,
    required this.reports,
    required this.docs,
  });

  final Repo repo;
  final List<LocalPackage> packages;

  /// Per-file scan results from the smell scanner.
  final List<FileReport> reports;
  final List<InstructionDoc> docs;

  bool vendored(String rel) => isVendored(rel, packages);

  LocalPackage? get rootPackage =>
      packages.where((p) => p.dir == '.').firstOrNull;

  /// Places where a developer or an agent looks for project commands:
  /// instruction files, the README, and task-runner files.
  late final List<CommandSource> localCommandSources = [
    for (final d in docs) CommandSource(d.path, d.text),
    for (final f in const [
      'README.md',
      'Makefile',
      'makefile',
      'justfile',
      'Justfile',
      'melos.yaml',
      'pubspec.yaml',
      'Taskfile.yml',
      'package.json',
    ])
      if (repo.read(f) case final text?) CommandSource(f, text),
  ];
}

/// Regexes that recognise a command for each common task.
final taskPatterns = <String, RegExp>{
  'test': RegExp(
    r'\b(?:fvm\s+)?(?:flutter|dart)\s+test\b|\bvery_good\s+test\b|'
    r'\bmelos\s+(?:run\s+)?test|\bmake\s+test|\bjust\s+test',
  ),
  'analyze': RegExp(
    r'\b(?:fvm\s+)?(?:flutter|dart)\s+analyze\b|'
    r'\bmelos\s+(?:run\s+)?(?:analyze|lint)|\bmake\s+(?:analyze|lint)|'
    r'\bjust\s+(?:analyze|lint)|\bdcm\s+analyze\b',
  ),
  'format': RegExp(
    r'\b(?:fvm\s+)?(?:dart|flutter)\s+format\b|'
    r'\bmelos\s+(?:run\s+)?format|\bmake\s+format|\bjust\s+format',
  ),
  'codegen': RegExp(
    r'\bbuild_runner\s+(?:build|watch)\b|'
    r'\bmelos\s+(?:run\s+)?(?:gen|generate|codegen|build_runner)|'
    r'\bmake\s+(?:gen|generate|codegen)|\bjust\s+(?:gen|generate|codegen)',
  ),
  'run': RegExp(r'\b(?:fvm\s+)?flutter\s+run\b|\bmake\s+run\b|\bjust\s+run\b'),
};
