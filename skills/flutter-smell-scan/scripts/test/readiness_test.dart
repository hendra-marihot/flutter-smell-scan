import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:smell_scan/smell_scan.dart';
import 'package:test/test.dart';

/// Writes [files] into a new temp project (a git repository unless [git] is
/// false) and returns its directory.
Future<Directory> project(Map<String, String> files, {bool git = true}) async {
  final dir = await Directory.systemTemp.createTemp('readiness_test');
  addTearDown(() => dir.delete(recursive: true));
  files.forEach((rel, text) {
    File(p.join(dir.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  });
  if (git) {
    await Process.run('git', ['init', '-q'], workingDirectory: dir.path);
  }
  return dir;
}

/// Runs the scan with the scorecard and returns the checks by id.
Future<Map<String, Map<String, Object?>>> checks(
  Map<String, String> files, {
  bool git = true,
  bool format = false,
}) async {
  final dir = await project(files, git: git);
  final result = await scanProject(
    ScanOptions(
      root: dir.path,
      runAnalyzer: false,
      readiness: true,
      formatCheck: format,
    ),
  );
  final r = result.json['readiness']! as Map<String, Object?>;
  return {
    for (final c in r['checks']! as List)
      (c as Map)['id'] as String: c.cast<String, Object?>(),
  };
}

String status(Map<String, Map<String, Object?>> cs, String id) =>
    cs[id]!['status']! as String;

List<String> evidence(Map<String, Map<String, Object?>> cs, String id) =>
    ((cs[id]!['evidence'] as List?) ?? const []).cast<String>();

const _pubspec = 'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n';

const _goodAgents = '''
# AGENTS.md

## Commands

```bash
flutter test
dart analyze --fatal-infos
dart format lib test
flutter run
```

## Architecture

`lib/features/` holds one folder per feature.

## Rules

- Never call repositories from widgets.
''';

void main() {
  test('the report has no readiness key without --readiness', () async {
    final dir = await project({'pubspec.yaml': _pubspec});
    final result = await scanProject(
      ScanOptions(root: dir.path, runAnalyzer: false),
    );
    expect(result.json.containsKey('readiness'), isFalse);
  });

  group('instruction-file', () {
    test('fails when there is no instruction file', () async {
      final cs = await checks({'pubspec.yaml': _pubspec});
      expect(status(cs, 'instruction-file'), 'fail');
    });

    test('follows @imports and passes a complete file', () async {
      final cs = await checks({
        'pubspec.yaml': _pubspec,
        'CLAUDE.md': '@AGENTS.md\n',
        'AGENTS.md': _goodAgents,
        'lib/features/a.dart': '',
      });
      expect(status(cs, 'instruction-file'), 'pass');
      expect(
        evidence(cs, 'instruction-file'),
        contains(startsWith('AGENTS.md (')),
      );
    });

    test('warns on missing sections and paths that do not exist', () async {
      final cs = await checks({
        'pubspec.yaml': _pubspec,
        '.gitignore': '.env\n',
        'CLAUDE.md': '''
Run `./scripts/gone.sh` and read `docs/missing.md` and `gone.dart`.
Needs a `package_config.json`.
Copy `.env` first. See `lib/<feature>/` and `*.g.dart`.
''',
      });
      expect(status(cs, 'instruction-file'), 'warn');
      final ev = evidence(cs, 'instruction-file');
      expect(ev, contains('Does not exist: CLAUDE.md: scripts/gone.sh'));
      expect(ev, contains('Does not exist: CLAUDE.md: docs/missing.md'));
      expect(ev, contains('Does not exist: CLAUDE.md: gone.dart'));
      expect(ev.where((e) => e.contains('package_config')), isEmpty);
      // Gitignored files, placeholders and globs are not broken references.
      expect(ev.where((e) => e.contains('.env')), isEmpty);
      expect(ev.where((e) => e.contains('<feature>')), isEmpty);
    });
  });

  group('task-commands', () {
    test('fails when neither test nor analyze is documented', () async {
      final cs = await checks({'pubspec.yaml': 'name: lib_only\n'});
      expect(status(cs, 'task-commands'), 'fail');
    });

    test('accepts Makefile targets and asks for codegen when used', () async {
      final cs = await checks({
        'pubspec.yaml': 'name: x\ndev_dependencies:\n  build_runner: any\n',
        'Makefile':
            'test:\n\tdart test\nlint:\n\tdart analyze\n'
            'fmt:\n\tdart format .\n',
      });
      expect(status(cs, 'task-commands'), 'warn');
      expect(evidence(cs, 'task-commands'), contains('codegen: not found'));
    });
  });

  group('non-interactive-scripts', () {
    test(
      'warns on prompts with no bypass, even when "CI" is in a string',
      () async {
        final cs = await checks({
          'pubspec.yaml': _pubspec,
          'scripts/bump.sh': '#!/bin/sh\nread -p "Version? " v\n',
          'release.py': 'print("skip CI notes")\nchoice = input("Go? ")\n',
        });
        expect(status(cs, 'non-interactive-scripts'), 'warn');
        expect(
          evidence(cs, 'non-interactive-scripts'),
          containsAll(['release.py:2 (input)', 'scripts/bump.sh:2 (read)']),
        );
      },
    );

    test(
      'ignores pipe reads and scripts with a --yes flag or CI check',
      () async {
        final cs = await checks({
          'pubspec.yaml': _pubspec,
          'scripts/loop.sh': 'ls | while IFS= read -r f; do echo "\$f"; done\n',
          'scripts/ask.sh':
              'if [ -z "\$CI" ]; then\n  read -p "Sure? " a\nfi\n',
          'tool/ask.py':
              'import sys\nif "--yes" not in sys.argv:\n  input("Go? ")\n',
        });
        expect(status(cs, 'non-interactive-scripts'), 'pass');
      },
    );
  });

  group('unguarded-dangerous-ops', () {
    test('warns on a deploy script with no guard', () async {
      final cs = await checks({
        'pubspec.yaml': _pubspec,
        // Comment and continuation lines must not shift the line number.
        'scripts/deploy.sh':
            '#!/bin/sh\n# Deploys the site.\n# Usage: deploy.sh\n'
            'echo a \\\n  b\nfirebase deploy --only hosting\n',
        'tool/tag.py':
            'import subprocess\nsubprocess.run(["git", "push", "origin", "v1"])\n',
      });
      expect(status(cs, 'unguarded-dangerous-ops'), 'warn');
      final ev = evidence(cs, 'unguarded-dangerous-ops');
      expect(ev, contains(startsWith('Unguarded: scripts/deploy.sh:6')));
      expect(ev, contains(startsWith('Unguarded: tool/tag.py:2')));
    });

    test('passes guarded scripts', () async {
      final cs = await checks({
        'pubspec.yaml': _pubspec,
        'scripts/release.sh':
            '#!/bin/sh\n[ "\$1" = "--dry-run" ] && exit 0\ngit tag v1\n',
      });
      expect(status(cs, 'unguarded-dangerous-ops'), 'pass');
    });

    test('warns on unguarded CI scripts and says CI runs them', () async {
      final cs = await checks({
        'pubspec.yaml': _pubspec,
        'scripts/release.sh':
            '#!/bin/sh\n[ "\$1" = "--dry-run" ] && exit 0\ngit tag v1\n',
        'scripts/ci/publish.sh': '#!/bin/sh\nshorebird release android\n',
      });
      expect(status(cs, 'unguarded-dangerous-ops'), 'warn');
      expect(
        cs['unguarded-dangerous-ops']!['summary'],
        startsWith('1 CI script'),
      );
      expect(
        evidence(cs, 'unguarded-dangerous-ops'),
        contains(
          'Unguarded, run by CI: scripts/ci/publish.sh:2 '
          '(`shorebird release`).',
        ),
      );
    });
  });

  test('inconsistent-patterns warns when two families have 3+ files', () async {
    final cs = await checks({
      'pubspec.yaml': _pubspec,
      for (var i = 0; i < 3; i++) ...{
        'lib/d$i.dart': "import 'package:dio/dio.dart';\n",
        'lib/h$i.dart': "import 'package:http/http.dart';\n",
      },
      'lib/r.dart': "import 'package:go_router/go_router.dart';\n",
    });
    expect(status(cs, 'inconsistent-patterns'), 'warn');
    expect(evidence(cs, 'inconsistent-patterns'), [
      'http-client: dio (3 files), http (3 files)',
    ]);
  });

  group('generated-noise', () {
    final generated = {
      'pubspec.yaml': _pubspec,
      'lib/a.dart': 'void a() {}\n',
      'lib/a.g.dart': List.filled(50, '// generated').join('\n'),
    };

    test('warns when generated code is a large share of search', () async {
      final cs = await checks(generated);
      expect(status(cs, 'generated-noise'), 'warn');
    });

    test('passes when .ignore hides generated files', () async {
      final cs = await checks({...generated, '.ignore': '*.g.dart\n'});
      expect(status(cs, 'generated-noise'), 'pass');
    });

    test('fails when build output is visible to search', () async {
      final cs = await checks({'pubspec.yaml': _pubspec, 'build/app.js': 'x'});
      expect(status(cs, 'generated-noise'), 'fail');
    });
  });

  group('lint-config', () {
    test('fails without analysis_options.yaml', () async {
      final cs = await checks({'pubspec.yaml': _pubspec});
      expect(status(cs, 'lint-config'), 'fail');
    });

    test('is unknown when a package include cannot be read', () async {
      final cs = await checks({
        'pubspec.yaml': _pubspec,
        'analysis_options.yaml':
            'include: package:flutter_lints/flutter.yaml\n',
      });
      expect(status(cs, 'lint-config'), 'unknown');
    });

    test('follows local includes and warns on key lints that are off', () async {
      final cs = await checks({
        'pubspec.yaml': _pubspec,
        'lints/base.yaml':
            'linter:\n  rules:\n    - avoid_print\n    - unawaited_futures\n'
            '    - prefer_const_constructors\n'
            '    - use_build_context_synchronously\n',
        'analysis_options.yaml':
            'include: lints/base.yaml\nlinter:\n  rules:\n    avoid_print: false\n',
      });
      expect(status(cs, 'lint-config'), 'warn');
      final configs = (cs['lint-config']!['details']! as Map)['configs'] as Map;
      final root = configs['analysis_options.yaml'] as Map;
      expect(root['keyLintsOff'], ['avoid_print']);
      expect(root['chain'], ['analysis_options.yaml', 'lints/base.yaml']);
    });

    test('resolves a package include through a local package', () async {
      final cs = await checks({
        'pubspec.yaml': _pubspec,
        'tool/my_lints/pubspec.yaml': 'name: my_lints\npublish_to: none\n',
        'tool/my_lints/lib/all.yaml':
            'linter:\n  rules:\n    - avoid_print\n    - unawaited_futures\n'
            '    - prefer_const_constructors\n'
            '    - use_build_context_synchronously\n',
        'analysis_options.yaml': 'include: package:my_lints/all.yaml\n',
      });
      expect(status(cs, 'lint-config'), 'pass');
    });
  });

  group('monorepo', () {
    const appPubspec =
        'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n'
        'environment:\n  sdk: ^3.8.0\n  flutter: ">=3.30.0"\n';
    const lints =
        'linter:\n  rules:\n    - avoid_print\n'
        '    - use_build_context_synchronously\n';

    test('reads each package lint config and finds the app', () async {
      final cs = await checks({
        'pubspec.yaml': 'name: ws\nworkspace:\n  - packages/*\n  - apps/app\n',
        'apps/app/pubspec.yaml': appPubspec,
        'apps/app/analysis_options.yaml': lints,
        'apps/app/lib/main.dart': 'void main() {}\n',
        'packages/core/pubspec.yaml':
            'name: core\nrepository: https://example.com/core\n'
            'dependencies:\n  flutter:\n    sdk: flutter\n',
        // A pure Dart tool does not need the Flutter-only lint.
        'packages/cli/pubspec.yaml': 'name: cli\n',
        'packages/cli/analysis_options.yaml':
            'linter:\n  rules:\n    - avoid_print\n',
        'packages/core/LICENSE': 'MIT',
        'packages/core/analysis_options.yaml': 'linter:\n  rules: []\n',
        'AGENTS.md': '```\nflutter test\ndart analyze\ndart format .\n```\n',
        'README.md': '# Workspace\n',
      });
      // A workspace member with a repository field is first-party.
      expect(status(cs, 'lint-config'), 'warn');
      expect(
        cs['lint-config']!['summary'],
        'packages/core/analysis_options.yaml turns off key lints: '
        'use_build_context_synchronously, avoid_print.',
      );
      // The app lives in apps/app, so `flutter run` is expected.
      expect(evidence(cs, 'task-commands'), contains('run: not found'));
      expect(
        evidence(cs, 'setup-docs'),
        contains(contains('pubspec.yaml environment.flutter')),
      );
    });
  });

  test(
    'stock flutter_lints keys pass when only recommended lints are off',
    () async {
      final cs = await checks({
        'pubspec.yaml': _pubspec,
        'analysis_options.yaml':
            'linter:\n  rules:\n    - avoid_print\n'
            '    - use_build_context_synchronously\n',
      });
      expect(status(cs, 'lint-config'), 'pass');
      expect(
        evidence(cs, 'lint-config').first,
        contains(
          'recommended off: prefer_const_constructors, unawaited_futures',
        ),
      );
    },
  );

  test('format counts unformatted files without changing them', () async {
    const ugly = 'void   main( ){print(1);}\n';
    final cs = await checks({
      'pubspec.yaml': 'name: x\n',
      '.dart_tool/package_config.json':
          '{"configVersion": 2, "packages": [{"name": "x", "rootUri": "../", '
          '"packageUri": "lib/", "languageVersion": "3.8"}]}',
      'lib/ok.dart': 'void main() {}\n',
      'lib/ugly.dart': ugly,
      'lib/skip.g.dart': ugly,
    }, format: true);
    expect(status(cs, 'format'), 'fail');
    expect(evidence(cs, 'format'), contains('Not formatted: lib/ugly.dart'));
    expect((cs['format']!['details']! as Map)['checked'], 2);
  });

  test('format is unknown when pub get has not run', () async {
    final cs = await checks({
      'pubspec.yaml': 'name: x\n',
      'lib/ugly.dart': 'void   main( ){}\n',
    }, format: true);
    expect(status(cs, 'format'), 'unknown');
  });

  group('ci-parity', () {
    test('fails without CI', () async {
      final cs = await checks({'pubspec.yaml': _pubspec});
      expect(status(cs, 'ci-parity'), 'fail');
    });

    test('warns when CI is stricter than the documented command', () async {
      final cs = await checks({
        'pubspec.yaml': _pubspec,
        'AGENTS.md': '```\nflutter test\ndart analyze\ndart format .\n```\n',
        '.github/workflows/ci.yml': '''
jobs:
  check:
    steps:
      - run: dart analyze --fatal-infos
      - run: dart format --set-exit-if-changed .
      # - run: flutter test
''',
      });
      expect(status(cs, 'ci-parity'), 'warn');
      expect(cs['ci-parity']!['summary'], contains('CI does not run: test'));
      expect(
        evidence(cs, 'ci-parity'),
        contains(startsWith('analyze: CI fails on infos')),
      );
    });

    test('counts a script named for a task that CI runs', () async {
      final cs = await checks({
        'pubspec.yaml': _pubspec,
        'AGENTS.md':
            '`./scripts/run_tests.sh`, `dart analyze`, `dart format .`\n',
        'scripts/run_tests.sh': 'CMD=(flutter)\n"\${CMD[@]}" test\n',
        '.github/workflows/ci.yml':
            'steps:\n  - run: ./scripts/run_tests.sh --reporter=github\n'
            '  - run: dart analyze\n  - run: dart format .\n',
      });
      expect(status(cs, 'ci-parity'), 'pass');
    });
  });

  group('setup-docs', () {
    test('fails without a README', () async {
      final cs = await checks({'pubspec.yaml': _pubspec});
      expect(status(cs, 'setup-docs'), 'fail');
    });

    test('asks for an env template when the app reads .env', () async {
      final cs = await checks({
        'pubspec.yaml': '$_pubspec  flutter_dotenv: any\n',
        '.fvmrc': '{"flutter": "3.50.0"}',
        'README.md':
            '# App\n## Setup\n## Environment\n## Architecture\n'
            '## Release\n',
      });
      expect(status(cs, 'setup-docs'), 'warn');
      expect(cs['setup-docs']!['summary'], contains('env template'));
    });
  });

  test(
    'a pure Dart package needs no Flutter pin or environment docs',
    () async {
      final cs = await checks({
        'pubspec.yaml': 'name: tool\n',
        'README.md': '# Tool\n## Install\n## Design\n## Release\n',
      });
      expect(status(cs, 'setup-docs'), 'pass');
    },
  );

  test('the scorecard works outside a git repository', () async {
    final cs = await checks({
      'pubspec.yaml': _pubspec,
      'AGENTS.md': _goodAgents,
      'lib/features/a.dart': '',
    }, git: false);
    expect(status(cs, 'instruction-file'), 'pass');
  });

  test('a readiness scan with the format check writes nothing', () async {
    final dir = await project({
      'pubspec.yaml': _pubspec,
      'AGENTS.md': _goodAgents,
      '.dart_tool/package_config.json':
          '{"configVersion": 2, "packages": [{"name": "app", "rootUri": "../", '
          '"packageUri": "lib/", "languageVersion": "3.8"}]}',
      'lib/ugly.dart': 'void   main( ){}\n',
      'scripts/deploy.sh': 'firebase deploy\n',
      '.github/workflows/ci.yml': 'steps:\n  - run: flutter test\n',
    });
    await Process.run('git', ['add', '-A'], workingDirectory: dir.path);

    Map<String, String> snapshot() => {
      for (final e in dir.listSync(recursive: true))
        if (e is File)
          e.path:
              '${e.lengthSync()}:${e.lastModifiedSync().microsecondsSinceEpoch}',
    };
    final before = snapshot();
    final result = await scanProject(
      ScanOptions(root: dir.path, runAnalyzer: false, readiness: true),
    );
    expect(snapshot(), before);
    // The format check really ran.
    final checks = (result.json['readiness']! as Map)['checks'] as List;
    final format =
        checks.firstWhere((c) => (c as Map)['id'] == 'format') as Map;
    expect(format['status'], 'fail');
  });
}
