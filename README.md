# flutter-smell-scan

A Claude Code plugin that finds code smells in a Flutter or Dart project and reports them ranked, verified, and with `file:line` for each one.

The plugin has two halves:

1. **A read-only scanner** (`skills/flutter-smell-scan/scripts/`), written in Dart on `package:analyzer`. It parses every source file and measures size, complexity, widget nesting, widget-helper methods, undisposed controllers, swallowed exceptions, data calls inside widgets, and mixed state management. It can also run `dart analyze` and include its diagnostics. It writes one JSON report and never writes to the scanned project.
2. **A skill** (`skills/flutter-smell-scan/SKILL.md`) that tells Claude how to use the report. Claude checks each high-severity finding against the source, drops false positives, reads the worst files for smells no metric can see, and writes a short ranked report.

The scanner does not need DCM. When `dcm` is installed, the skill also uses it for unused-code and duplication checks.

## Requirements

- Dart 3.8 or later on `PATH` (the Flutter SDK includes it).
- No `pub get` in the target project. Analyzer diagnostics need one, and the skill asks before running it.

## Install

As a plugin from GitHub:

```bash
claude plugin marketplace add hendra-marihot/flutter-smell-scan
claude plugin install flutter-smell-scan@flutter-smell-scan
```

To update later, refresh the marketplace, then update the plugin, and restart Claude Code:

```bash
claude plugin marketplace update flutter-smell-scan
claude plugin update flutter-smell-scan@flutter-smell-scan
```

From a local clone, pass the clone's path to `marketplace add` instead of `hendra-marihot/flutter-smell-scan`.

For local development, load the checkout without installing it:

```bash
claude --plugin-dir /path/to/flutter-smell-scan
```

Or copy only the skill:

```bash
cp -R skills/flutter-smell-scan ~/.claude/skills/
```

## Use

Ask Claude in a Flutter project, for example: "scan this project for code smells" or "where should we refactor first?".

To run the scanner by hand:

```bash
skills/flutter-smell-scan/scripts/scan.sh <project-dir> --out /tmp/smell-report.json
skills/flutter-smell-scan/scripts/scan.sh --help
```

The first run resolves the scanner's own packages. Options:

| Option | Effect |
|---|---|
| `--out <file>` | Report path. Must be outside the project. Defaults to the system temp directory. |
| `--include-tests` | Also scan `test/`, `integration_test/`, `test_driver/`. |
| `--no-analyze` | Skip `dart analyze`. Much faster on large projects. |
| `--set key=value` | Override a threshold, for example `--set long-function=40`. |
| `--top <n>` | Number of hotspot files in the report (default 15). |

## What it detects

See [`skills/flutter-smell-scan/references/smell-catalog.md`](skills/flutter-smell-scan/references/smell-catalog.md) for every smell, its threshold, its known false positives, and the usual fix.

| Group | Smells |
|---|---|
| Lifecycle and errors | `missing-dispose`, `listener-not-removed`, `swallowed-exception` |
| Layering | `ui-layer-leak`, `mixed-state-management` |
| Flutter structure | `widget-helper-method`, `deep-widget-nesting`, `long-build-method`, `setstate-heavy`, `oversized-state-holder` |
| Size and complexity | `long-file`, `large-class`, `long-function`, `high-complexity`, `long-parameter-list` |

Generated files (`*.g.dart`, `*.freezed.dart`, `*.mocks.dart`, and others) and platform folders are skipped.

## Limits

- The scanner parses code without resolving types, so it identifies widgets by their `build(BuildContext)` method and types by name. That is why Claude verifies the high findings before reporting them.
- `deep-widget-nesting` is approximate: it counts every capitalised constructor call, including `TextStyle` and `EdgeInsets`.
- It does not detect duplicated or unused code. DCM does, on its paid plans.

## Develop

```bash
cd skills/flutter-smell-scan/scripts
dart pub get
dart analyze
dart test
```
