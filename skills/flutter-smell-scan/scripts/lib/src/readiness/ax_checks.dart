/// Agent-experience checks: what an agent needs to work in the repo
/// without guessing.
library;

import 'package:path/path.dart' as p;

import 'instructions.dart';
import 'model.dart';
import 'repo.dart';

const _maxInstructionLines = 500;

Future<ReadinessCheck> instructionFileCheck(ReadinessContext c) async {
  final docs = c.docs;
  if (docs.isEmpty) {
    return ReadinessCheck(
      id: 'instruction-file',
      area: 'ax',
      status: CheckStatus.fail,
      summary: 'No agent instruction file was found.',
      evidence: [
        'Looked for ${instructionFileNames.join(', ')}, '
            '.cursor/rules/ and .github/instructions/.',
      ],
      fix:
          'Add AGENTS.md (and a CLAUDE.md that contains `@AGENTS.md`) with '
          'the commands to test, analyze, format and generate code, a map of '
          'the main folders, and the project rules.',
    );
  }
  final a = await analyzeInstructions(c.repo, docs, c.packages);
  final missing = [
    if (!a.hasCommands) 'commands',
    if (!a.hasArchitecture) 'architecture map',
    if (!a.hasRules) 'project rules',
  ];
  final problems = [
    if (missing.isNotEmpty) 'missing ${missing.join(', ')}',
    if (a.broken.isNotEmpty)
      '${a.broken.length} reference(s) that do not exist',
    if (a.totalLines > _maxInstructionLines)
      '${a.totalLines} lines, which every session loads into context',
  ];
  return ReadinessCheck(
    id: 'instruction-file',
    area: 'ax',
    status: problems.isEmpty ? CheckStatus.pass : CheckStatus.warn,
    summary: problems.isEmpty
        ? 'Instruction files cover commands, architecture and rules, and '
              'every path they mention exists.'
        : 'Instruction files have problems: ${problems.join('; ')}.',
    evidence: [
      for (final d in docs)
        '${d.path} (${d.lines} lines'
            '${d.importedBy == null ? '' : ', imported by ${d.importedBy}'})',
      'Sections: commands ${a.hasCommands ? 'yes' : 'no'}, architecture '
          '${a.hasArchitecture ? 'yes' : 'no'}, rules ${a.hasRules ? 'yes' : 'no'}.',
      for (final b in a.broken.take(15)) 'Does not exist: $b',
    ],
    fix:
        'Add the missing sections, and fix or remove references to paths '
        'and commands that do not exist.',
    details: {'broken': a.broken, 'totalLines': a.totalLines},
  );
}

ReadinessCheck taskCommandsCheck(ReadinessContext c) {
  final usesCodegen = c.packages.any(
    (p) => !p.vendored && p.dependsOn('build_runner'),
  );
  // Any first-party Flutter package with a lib/main*.dart is an app.
  final isApp = c.packages.any(
    (pkg) =>
        !pkg.vendored &&
        pkg.dependsOn('flutter') &&
        c.repo.files.any(
          (f) => RegExp(
            '^${pkg.dir == '.' ? '' : '${RegExp.escape(pkg.dir)}/'}'
            r'lib/main\w*\.dart$',
          ).hasMatch(f),
        ),
  );
  final tasks = [
    'test',
    'analyze',
    'format',
    if (usesCodegen) 'codegen',
    if (isApp) 'run',
  ];
  final scripts = [
    for (final f in c.repo.sourceFiles)
      if (RegExp(r'^(scripts|tool)/[^/]+\.(sh|py|dart)$').hasMatch(f) &&
          !c.vendored(f))
        if (c.repo.read(f) case final text?) CommandSource(f, text),
  ];
  final sources = [...c.localCommandSources, ...scripts];
  final foundIn = <String, List<String>>{};
  for (final task in tasks) {
    final re = taskPatterns[task]!;
    foundIn[task] = [
      for (final s in sources)
        if (re.hasMatch(s.text)) s.label,
    ];
  }
  final missing = [
    for (final t in tasks)
      if (foundIn[t]!.isEmpty) t,
  ];
  final status = missing.isEmpty
      ? CheckStatus.pass
      : missing.contains('test') && missing.contains('analyze')
      ? CheckStatus.fail
      : CheckStatus.warn;
  return ReadinessCheck(
    id: 'task-commands',
    area: 'ax',
    status: status,
    summary: missing.isEmpty
        ? 'Every common task has a documented command.'
        : 'No documented command for: ${missing.join(', ')}.',
    evidence: [
      for (final t in tasks)
        foundIn[t]!.isEmpty
            ? '$t: not found'
            : '$t: ${foundIn[t]!.take(3).join(', ')}',
    ],
    fix:
        'Write one command for each missing task in the instruction file, '
        'or add a Makefile/melos script for it, so an agent does not have to '
        'guess the flags.',
  );
}

/// A script and its text, for the script checks.
class _Script {
  _Script(this.path, this.text);
  final String path;
  final String text;
  bool get isShell => RegExp(r'\.(sh|bash|zsh)$').hasMatch(path);
  bool get isPython => path.endsWith('.py');
  bool get isRuby => path.endsWith('.rb') || p.basename(path) == 'Fastfile';
  bool get isDart => path.endsWith('.dart');
}

List<_Script> _scripts(ReadinessContext c) {
  final out = <_Script>[];
  for (final f in c.repo.sourceFiles) {
    final segs = f.split('/');
    if (segs.contains('example') || segs.contains('test') || c.vendored(f)) {
      continue;
    }
    final base = p.basename(f);
    if (base.startsWith('test_') || RegExp(r'_test\.\w+$').hasMatch(base)) {
      continue;
    }
    final isScript =
        RegExp(r'\.(sh|bash|zsh|py|rb)$').hasMatch(f) ||
        base == 'Fastfile' ||
        (f.endsWith('.dart') &&
            segs.length >= 2 &&
            const {'bin', 'tool', 'scripts'}.contains(segs[segs.length - 2]));
    if (!isScript) continue;
    final text = c.repo.read(f);
    if (text != null) out.add(_Script(f, text));
  }
  return out;
}

/// The first interactive prompt in [s], as `line: label`, or null.
({int line, String label})? _firstPrompt(_Script s) {
  final lines = s.text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('#') || trimmed.startsWith('//')) continue;
    String? label;
    if (s.isShell) {
      final read = RegExp(
        r'(^|[;&|]\s*|\b(?:then|do|else)\s+)read\b',
      ).firstMatch(line);
      final readsPipe =
          RegExp(r'\b(while|until)\b[^;]*\bread\b').hasMatch(line) ||
          RegExp(r'\|\s*read\b').hasMatch(line) ||
          RegExp(r'\bread\b[^;|]*(<<<|<\s*[\w"$(])').hasMatch(line);
      if (read != null && !readsPipe) label = 'read';
      if (RegExp(r'^\s*select\s+\w+\s+in\b').hasMatch(line)) label = 'select';
    } else if (s.isPython) {
      final m = RegExp(
        r'(?<![\w.])(input|getpass)\(|\b(click\.(?:confirm|prompt)|questionary\.\w+|inquirer\.\w+)\(',
      ).firstMatch(line);
      if (m != null) label = m.group(1) ?? m.group(2);
    } else if (s.isRuby) {
      final m = RegExp(
        r'\b(STDIN\.gets|\$stdin\.gets|UI\.(?:confirm|select|input|password)|prompt)\(?',
      ).firstMatch(line);
      if (m != null && !line.contains('def ')) label = m.group(1);
    } else if (s.isDart) {
      final m = RegExp(
        r'stdin\.(readLineSync|readByteSync)\(',
      ).firstMatch(line);
      if (m != null) label = 'stdin.${m.group(1)}';
    }
    if (label != null) return (line: i + 1, label: label);
  }
  return null;
}

/// Code that reads the `CI` environment variable. The bare word "CI" in a
/// string or comment does not count.
const _ciEnv =
    r'''\$\{?CI\b|environ(?:\.get)?\s*[(\[]\s*["']CI["']|getenv\(\s*["']CI["']|'''
    r'''ENV\[\s*["']CI["']|environment\[\s*["']CI["']|\bis_ci\b''';

/// A flag or environment check that lets the script run without a person.
final _bypass = RegExp(
  r'''--yes\b|--no-input\b|--non-interactive\b|--assume-yes\b|--force\b|'''
  r'''["']-y["']|\s-y\)|isatty|\[\s*-t\s+[01]\s*\]|'''
  r'''stdin\.hasTerminal|--no-prompt\b|'''
  '$_ciEnv',
);

ReadinessCheck nonInteractiveScriptsCheck(ReadinessContext c) {
  final interactive = <String>[];
  var withBypass = 0;
  for (final s in _scripts(c)) {
    final prompt = _firstPrompt(s);
    if (prompt == null) continue;
    if (_bypass.hasMatch(s.text)) {
      withBypass++;
      continue;
    }
    interactive.add('${s.path}:${prompt.line} (${prompt.label})');
  }
  return ReadinessCheck(
    id: 'non-interactive-scripts',
    area: 'ax',
    status: interactive.isEmpty ? CheckStatus.pass : CheckStatus.warn,
    summary: interactive.isEmpty
        ? 'No script waits for keyboard input without a way to skip it.'
        : '${interactive.length} script(s) wait for keyboard input and have '
              'no flag or CI check to skip it. An agent that runs them hangs.',
    evidence: [
      ...interactive.take(15),
      if (withBypass > 0)
        '$withBypass interactive script(s) already have a --yes flag or CI check.',
    ],
    fix:
        'Add a `--yes` (or `--non-interactive`) flag that takes the default '
        'answers, and skip prompts when `CI` is set or stdin is not a terminal.',
  );
}

final _dangerCommand = RegExp(
  r'firebase\s+deploy|firebase\s+appdistribution|shorebird\s+(release|patch)|'
  r'\b(deliver|supply|pilot|upload_to_\w+|firebase_app_distribution|'
  r'app_store_connect_api_key|appcenter_upload)\s*\(|'
  r'fastlane\s+\S*\s*(release|deploy|beta|upload|submit|production)|'
  r'gcloud\s+.*\bdeploy\b|kubectl\s+(apply|delete)|terraform\s+(apply|destroy)|'
  r'(dart|flutter)\s+pub\s+publish|git\s+push\b|git\s+tag\b|'
  r'gh\s+release\s+create|rm\s+-rf\s+[/~$]|DROP\s+(TABLE|DATABASE)|'
  r'TRUNCATE\s+TABLE|xcrun\s+altool|codemagic-cli\S*\s+publish',
);

final _guard = RegExp(
  r'--dry-run|dry_run|DRY_RUN|--confirm|CONFIRM|'
  '$_ciEnv',
);

ReadinessCheck dangerousOpsCheck(ReadinessContext c) {
  final ciText = ciFiles(c.repo).map((f) => c.repo.read(f) ?? '').join('\n');
  final unguarded = <String>[];
  final ciOnly = <String>[];
  final guarded = <String>[];

  void consider(String label, String text, {required bool runByCi}) {
    // `["git", "push"]` in Python means `git push`.
    final flat = joinContinuations(
      stripHashComments(text),
    ).replaceAll(RegExp(r'''["']\s*,\s*["']'''), ' ');
    final m = _dangerCommand.firstMatch(flat);
    if (m == null) return;
    final line = '\n'.allMatches(flat.substring(0, m.start)).length + 1;
    final hit = '$label:$line (`${m.group(0)!.trim()}`)';
    final hasPrompt = _firstPrompt(_Script(label, text)) != null;
    if (hasPrompt || _guard.hasMatch(flat)) {
      guarded.add(hit);
    } else if (runByCi) {
      ciOnly.add(hit);
    } else {
      unguarded.add(hit);
    }
  }

  for (final s in _scripts(c)) {
    final runByCi =
        s.path.split('/').contains('ci') ||
        ciText.contains(s.path) ||
        ciText.contains('./${s.path}');
    consider(s.path, s.text, runByCi: runByCi);
  }
  // Makefile targets, one at a time.
  final mk = c.repo.read('Makefile') ?? c.repo.read('makefile');
  if (mk != null) {
    for (final m in RegExp(
      r'^([\w.-]+)\s*:[^\n]*\n((?:\t[^\n]*\n?)*)',
      multiLine: true,
    ).allMatches(mk)) {
      consider('Makefile target `${m.group(1)}`', m.group(2)!, runByCi: false);
    }
  }
  // melos scripts.
  final melos = c.repo.read('melos.yaml');
  if (melos != null) consider('melos.yaml', melos, runByCi: false);

  return ReadinessCheck(
    id: 'unguarded-dangerous-ops',
    area: 'ax',
    status: unguarded.isEmpty && ciOnly.isEmpty
        ? CheckStatus.pass
        : CheckStatus.warn,
    summary: unguarded.isNotEmpty
        ? '${unguarded.length} script(s) deploy, release or push with no '
              'confirmation, dry-run or CI check. One wrong command from an '
              'agent ships or deletes something.'
        : ciOnly.isNotEmpty
        ? '${ciOnly.length} CI script(s) deploy, release or push with no '
              'guard. CI is their normal caller, but an agent can still run '
              'them locally.'
        : 'Every deploy, release or push script found has a guard.',
    evidence: [
      for (final u in unguarded.take(15)) 'Unguarded: $u',
      if (guarded.isNotEmpty)
        'Guarded by a prompt, dry-run or CI check: ${guarded.take(5).join(', ')}.',
      if (ciOnly.isNotEmpty)
        'Unguarded, run by CI: ${ciOnly.take(5).join(', ')}.',
    ],
    fix:
        'Make the script refuse to run unless `CI` is set or `--confirm` is '
        'passed, and add a `--dry-run` that prints what it would do.',
  );
}

/// CI configuration files, including local GitHub actions.
List<String> ciFiles(Repo repo) => [
  for (final f in repo.files)
    if (RegExp(
      r'^(\.github/workflows/[^/]+\.ya?ml|\.github/actions/.+/action\.ya?ml|'
      r'codemagic\.ya?ml|bitrise\.ya?ml|\.gitlab-ci\.ya?ml|'
      r'azure-pipelines\.ya?ml|\.circleci/config\.ya?ml|Jenkinsfile|'
      r'bitbucket-pipelines\.ya?ml|\.travis\.ya?ml|appveyor\.ya?ml)$',
    ).hasMatch(f))
      f,
];

ReadinessCheck inconsistentPatternsCheck(ReadinessContext c) {
  // concern -> family -> files
  final byConcern = <String, Map<String, List<String>>>{};
  for (final r in c.reports) {
    if (c.vendored(r.path)) continue;
    r.families.forEach((concern, families) {
      for (final f in families) {
        byConcern
            .putIfAbsent(concern, () => {})
            .putIfAbsent(f, () => [])
            .add(r.path);
      }
    });
  }
  final mixed = <String>[];
  final details = <String, Object?>{};
  for (final concern in byConcern.keys.toList()..sort()) {
    final families = byConcern[concern]!.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    details[concern] = {
      for (final e in families) e.key: e.value.take(20).toList(),
    };
    // A minority family in 1-2 files is a leftover, not a second pattern.
    if (families.length >= 2 && families[1].value.length >= 3) {
      mixed.add(
        '$concern: ${families.map((e) => '${e.key} (${e.value.length} files)').join(', ')}',
      );
    }
  }
  return ReadinessCheck(
    id: 'inconsistent-patterns',
    area: 'ax',
    status: mixed.isEmpty ? CheckStatus.pass : CheckStatus.warn,
    summary: mixed.isEmpty
        ? 'Each concern (state, HTTP, DI, routing, serialization, logging) '
              'uses one library family.'
        : '${mixed.length} concern(s) are solved in 2 or more ways. An agent '
              'copies whichever example it finds first.',
    evidence: mixed,
    fix:
        'Name the one family to use for each concern in the instruction file, '
        'and migrate the minority files when they are next touched.',
    details: details,
  );
}

final generatedDartSuffixes = [
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
  '.graphql.dart',
];

bool isGeneratedPath(String f) =>
    generatedDartSuffixes.any(f.endsWith) ||
    (f.endsWith('.dart') && f.contains('/__generated__/'));

/// [rel] relative to the package that owns it.
String _insidePackage(String rel, List<LocalPackage> packages) {
  final pkg = owningPackage(rel, packages);
  return pkg == null || pkg.dir == '.' ? rel : p.relative(rel, from: pkg.dir);
}

ReadinessCheck generatedNoiseCheck(ReadinessContext c) {
  final repo = c.repo;
  var generatedFiles = 0, generatedLines = 0, dartLines = 0;
  for (final f in repo.files) {
    if (!f.endsWith('.dart')) continue;
    final lines = '\n'.allMatches(repo.read(f) ?? '').length;
    dartLines += lines;
    if (isGeneratedPath(f)) {
      generatedFiles++;
      generatedLines += lines;
    }
  }
  final share = dartLines == 0 ? 0 : (generatedLines * 100 / dartLines).round();

  final ignoreText = [
    repo.read('.ignore') ?? '',
    repo.read('.rgignore') ?? '',
  ].join('\n');
  final ignoreCovers = RegExp(
    r'\.g\.dart|\.freezed\.dart|generated',
  ).hasMatch(ignoreText);

  // `build/` and `coverage/` count only at a package root, so a feature
  // folder such as `lib/features/coverage/` is not build output.
  final buildOutput = [
    for (final f in repo.files)
      if (f.split('/').contains('.dart_tool') ||
          RegExp(r'^(build|coverage)/').hasMatch(_insidePackage(f, c.packages)))
        f,
  ];
  final bigData = [
    for (final f in repo.files)
      if (RegExp(r'\.(json|graphql|log|txt|csv|lcov|info|arb)$').hasMatch(f))
        if (repo.size(f) > 1000000) f,
  ];
  final vendored = [
    for (final p in c.packages)
      if (p.vendored) p.dir,
  ];

  final status = buildOutput.isNotEmpty
      ? CheckStatus.fail
      : (share >= 20 && !ignoreCovers) || bigData.isNotEmpty
      ? CheckStatus.warn
      : CheckStatus.pass;
  return ReadinessCheck(
    id: 'generated-noise',
    area: 'ax',
    status: status,
    summary: switch (status) {
      CheckStatus.fail =>
        'Build output is committed or not ignored, so searches return it.',
      CheckStatus.warn =>
        'Generated code or large data files make up much of what an agent '
            'searches.',
      _ => 'Generated code and build output do not crowd agent searches.',
    },
    evidence: [
      '$generatedFiles generated Dart files ($share% of Dart lines) are '
          'visible to search${ignoreCovers ? ', but .ignore/.rgignore hides them' : ''}.',
      if (buildOutput.isNotEmpty)
        '${buildOutput.length} build/coverage files are visible, e.g. '
            '${buildOutput.take(3).join(', ')}.',
      for (final f in bigData.take(5)) 'Large data file: $f',
      if (vendored.isNotEmpty)
        'Vendored package copies: ${vendored.join(', ')}. Their code shows '
            'up in searches next to project code.',
    ],
    fix:
        'Add a `.ignore` file (read by ripgrep, which agent search tools use) '
        'with the generated patterns such as `*.g.dart` and `*.freezed.dart`. '
        'Git still tracks the files. Remove build output from git.',
    details: {
      'generatedFiles': generatedFiles,
      'generatedLines': generatedLines,
      'dartLines': dartLines,
    },
  );
}
