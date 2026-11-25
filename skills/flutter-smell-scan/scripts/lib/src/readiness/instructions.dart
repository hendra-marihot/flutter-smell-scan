/// Finds and inspects agent instruction files.
library;

import 'package:path/path.dart' as p;

import 'model.dart';
import 'repo.dart';

/// Instruction files at fixed paths. `.cursor/rules/` and
/// `.github/instructions/` are added by pattern.
const instructionFileNames = [
  'CLAUDE.md',
  '.claude/CLAUDE.md',
  'AGENTS.md',
  'GEMINI.md',
  '.cursorrules',
  '.github/copilot-instructions.md',
];

final _fence = RegExp(r'```[\s\S]*?```');
final _inlineCode = RegExp(r'`([^`\n]+)`');

/// Instruction files plus the files they import with `@path` (Claude Code
/// syntax), up to 4 levels deep.
List<InstructionDoc> loadInstructionDocs(Repo repo) {
  final docs = <String, InstructionDoc>{};

  void add(String rel, String? importedBy, int depth) {
    if (docs.containsKey(rel) || depth > 4) return;
    final text = repo.read(rel);
    if (text == null) return;
    docs[rel] = InstructionDoc(rel, text, importedBy: importedBy);
    final prose = text.replaceAll(_fence, '').replaceAll(_inlineCode, '');
    for (final m in RegExp(r'(?:^|\s)@([^\s@`]+)').allMatches(prose)) {
      final target = m.group(1)!.replaceAll(RegExp(r'[.,;:)]+$'), '');
      if (target.startsWith('~') || target.startsWith('/')) continue;
      if (!target.contains('.') && !target.contains('/')) continue;
      final rel2 = p.normalize(p.join(p.dirname(rel), target));
      if (rel2.startsWith('..')) continue;
      add(rel2, rel, depth + 1);
    }
  }

  for (final f in instructionFileNames) {
    add(f, null, 0);
  }
  for (final f in repo.files) {
    if ((f.startsWith('.cursor/rules/') &&
            (f.endsWith('.md') || f.endsWith('.mdc'))) ||
        (f.startsWith('.github/instructions/') && f.endsWith('.md'))) {
      add(f, null, 0);
    }
  }
  return docs.values.toList();
}

/// What the instruction files cover, and the paths and commands they
/// mention that do not exist.
class InstructionAnalysis {
  InstructionAnalysis({
    required this.hasCommands,
    required this.hasArchitecture,
    required this.hasRules,
    required this.broken,
    required this.totalLines,
  });

  final bool hasCommands;
  final bool hasArchitecture;
  final bool hasRules;

  /// `"AGENTS.md: scripts/old.sh"` for each reference that does not resolve.
  final List<String> broken;
  final int totalLines;
}

final _commandLine = RegExp(
  r'^\s*(?:\$\s*)?(?:fvm\s+)?(?:flutter|dart|melos|make|just|\./|bash\s|sh\s|'
  r'python3?\s|npm\s|yarn\s|very_good\s|fastlane\s|bundle\s|rg\s|git\s)',
  multiLine: true,
);

final _architectureHeading = RegExp(
  r'^#+\s.*\b(architecture|structure|layout|map|folders?|director(y|ies)|'
  r'modules?|overview|codebase)\b',
  caseSensitive: false,
  multiLine: true,
);

final _rulesHeading = RegExp(
  r"^#+\s.*\b(rules?|conventions?|patterns?|guidelines?|forbidden|do not|don'?t|"
  r'pitfalls?|style|gotchas?|must|standards?|testing)\b',
  caseSensitive: false,
  multiLine: true,
);

final _ruleLine = RegExp(
  r"^\s*([-*]|\d+\.)\s.*\b(never|always|must|do not|don'?t|avoid|prefer)\b",
  caseSensitive: false,
  multiLine: true,
);

Future<InstructionAnalysis> analyzeInstructions(
  Repo repo,
  List<InstructionDoc> docs,
  List<LocalPackage> packages,
) async {
  final all = docs.map((d) => d.text).join('\n\n');

  final fences = _fence.allMatches(all).map((m) => m.group(0)!).toList();
  final inline = _inlineCode.allMatches(all).map((m) => m.group(1)!).toList();
  final hasCommands =
      fences.any(_commandLine.hasMatch) ||
      inline.where((c) => _commandLine.hasMatch(c)).length >= 2;

  final libPaths = inline
      .where((c) => RegExp(r'^(lib|packages)/[\w/]+').hasMatch(c))
      .length;
  final hasArchitecture = _architectureHeading.hasMatch(all) || libPaths >= 3;
  final hasRules =
      _rulesHeading.hasMatch(all) || _ruleLine.allMatches(all).length >= 3;

  // Path and command references that do not resolve.
  final unresolved = <String, String>{}; // token -> doc path
  for (final d in docs) {
    final tokens = <String>{
      for (final m in _inlineCode.allMatches(d.text)) ...[
        m.group(1)!.trim(),
        // Paths inside a command span: `./scripts/x.sh --flag`.
        ...RegExp(
          r'(?:^|\s)(\./[\w./-]+)',
        ).allMatches(m.group(1)!).map((x) => x.group(1)!),
      ],
      for (final f in _fence.allMatches(d.text))
        ...RegExp(
          r'(?:^|\s)(\./[\w./-]+|(?:scripts|tool|bin)/[\w./-]+\.\w+)',
          multiLine: true,
        ).allMatches(f.group(0)!).map((m) => m.group(1)!),
    };
    for (final raw in tokens) {
      final token = _pathToken(raw);
      if (token == null) continue;
      if (!_resolves(repo, token, d.path, packages)) {
        unresolved.putIfAbsent(token, () => d.path);
      }
    }
    for (final ref in _taskRunnerRefs(d.text)) {
      if (!_taskRunnerTargetExists(repo, ref)) {
        unresolved.putIfAbsent(ref, () => d.path);
      }
    }
  }
  // Gitignored paths such as `.env` are expected to be missing in a fresh
  // clone; the docs say how to create them.
  final ignored = await repo.ignored(
    unresolved.keys.where((k) => !k.contains(' ')),
  );
  final broken = [
    for (final e in unresolved.entries)
      if (!ignored.contains(e.key)) '${e.value}: ${e.key}',
  ];

  return InstructionAnalysis(
    hasCommands: hasCommands,
    hasArchitecture: hasArchitecture,
    hasRules: hasRules,
    broken: broken,
    totalLines: docs.fold(0, (s, d) => s + d.lines),
  );
}

final _fileWithExt = RegExp(
  r'^\.?[\w-]+(\.[\w-]+)*\.(dart|md|mdc|ya?ml|json|sh|py|rb|graphql|txt|toml|'
  r'gradle|kts|xml|plist|arb|lock)$',
  caseSensitive: false,
);

/// Returns the path a code span names, or null when it is not a path:
/// placeholders (`<feature>`), globs, `...`, calls, URLs, and options.
String? _pathToken(String raw) {
  var t = raw.trim();
  if (t.isEmpty || t.contains(RegExp(r'''[\s<>*{}$|()=,'"\[\]:]'''))) {
    return null;
  }
  if (t.contains('...') || t.contains('//')) return null;
  // `_event.dart` names a file suffix, not a file.
  if (t.startsWith('-') ||
      t.startsWith('@') ||
      t.startsWith('~') ||
      t.startsWith('_')) {
    return null;
  }
  t = t.replaceFirst(RegExp(r'^\./'), '').replaceFirst(RegExp(r'/+$'), '');
  t = t.replaceFirst(RegExp(r'[.,;]+$'), '');
  if (t.isEmpty) return null;
  if (t.contains('/')) {
    return RegExp(r'^[\w.\-/]+$').hasMatch(t) ? t : null;
  }
  // A bare `pubspec.yaml` or `package_config.json` names a kind of file.
  // Only bare Dart and Markdown names point at one project file.
  return _fileWithExt.hasMatch(t) && RegExp(r'\.(dart|md|mdc)$').hasMatch(t)
      ? t
      : null;
}

bool _resolves(
  Repo repo,
  String token,
  String docPath,
  List<LocalPackage> packages,
) {
  if (repo.existsOnDisk(token)) return true;
  final besideDoc = p.normalize(p.join(p.dirname(docPath), token));
  if (!besideDoc.startsWith('..') && repo.existsOnDisk(besideDoc)) return true;
  for (final pkg in packages) {
    final inLib = p.normalize(p.join(pkg.dir, 'lib', token));
    if (repo.existsOnDisk(inLib)) return true;
  }
  if (!token.contains('/')) {
    final lower = token.toLowerCase();
    return repo.files.any((f) => p.basename(f).toLowerCase() == lower);
  }
  return repo.files.any(
    (f) =>
        f.endsWith('/$token') ||
        f.startsWith('$token/') ||
        f.contains('/$token/'),
  );
}

/// `make X`, `melos run X` and `just X` mentioned in code.
Iterable<String> _taskRunnerRefs(String text) sync* {
  final code = [
    ..._fence.allMatches(text).map((m) => m.group(0)!),
    ..._inlineCode.allMatches(text).map((m) => m.group(1)!),
  ].join('\n');
  for (final m in RegExp(
    r'(?:^|[\s`$])(make|melos run|just)\s+([\w:-]+)',
    multiLine: true,
  ).allMatches(code)) {
    yield '${m.group(1)} ${m.group(2)}';
  }
}

bool _taskRunnerTargetExists(Repo repo, String ref) {
  final parts = ref.split(' ');
  final target = parts.last;
  switch (parts.first) {
    case 'make':
      final mk = repo.read('Makefile') ?? repo.read('makefile');
      return mk != null &&
          RegExp(
            '^${RegExp.escape(target)}\\s*:',
            multiLine: true,
          ).hasMatch(mk);
    case 'just':
      final jf = repo.read('justfile') ?? repo.read('Justfile');
      return jf != null &&
          RegExp(
            '^@?${RegExp.escape(target)}\\b[^\\n]*:',
            multiLine: true,
          ).hasMatch(jf);
    default: // melos run
      final melos =
          '${repo.read('melos.yaml') ?? ''}\n${repo.read('pubspec.yaml') ?? ''}';
      return RegExp(
        '^\\s+${RegExp.escape(target)}\\s*:',
        multiLine: true,
      ).hasMatch(melos);
  }
}
