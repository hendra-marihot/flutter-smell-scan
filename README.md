# flutter-smell-scan

A Claude Code plugin with two skills for Flutter and Dart projects:

- **`flutter-smell-scan`** finds code smells and reports them ranked, verified, and with `file:line` for each one.
- **`flutter-agent-readiness`** audits how ready the repository is for AI coding agents. It reports a pass/warn/fail scorecard for instruction files, commands, scripts, CI, lint config and formatting.

Both skills use the same scanner. Each skill has two halves:

1. **A read-only scanner** (`skills/flutter-smell-scan/scripts/`), written in Dart on `package:analyzer`. It parses every source file and measures size, complexity, widget nesting, widget-helper methods, undisposed controllers, swallowed exceptions, data calls inside widgets, and mixed state management. It can also run `dart analyze` and include its diagnostics. It writes one JSON report and never writes to the scanned project.
2. **A skill** (`SKILL.md`) that tells Claude how to use the report. Claude checks each high-severity finding against the source, drops false positives, reads the worst files for smells no metric can see, and writes a short ranked report.

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

Or copy the skills (keep them side by side, because `flutter-agent-readiness` uses the scanner in `flutter-smell-scan`):

```bash
cp -R skills/flutter-smell-scan skills/flutter-agent-readiness ~/.claude/skills/
```

## Use

Ask Claude in a Flutter project, for example: "scan this project for code smells", "where should we refactor first?", or "is this repo ready for AI agents?".

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
| `--readiness` | Add the agent-readiness scorecard (`readiness` key) to the report. |
| `--no-format` | With `--readiness`, skip the `dart format --output=none` check. |

## What it detects

See [`skills/flutter-smell-scan/references/smell-catalog.md`](skills/flutter-smell-scan/references/smell-catalog.md) for every smell, its threshold, its known false positives, and the usual fix.

| Group | Smells |
|---|---|
| Lifecycle and errors | `missing-dispose`, `listener-not-removed`, `swallowed-exception` |
| Layering | `ui-layer-leak`, `mixed-state-management` |
| Flutter structure | `widget-helper-method`, `deep-widget-nesting`, `long-build-method`, `setstate-heavy`, `oversized-state-holder` |
| Size and complexity | `long-file`, `large-class`, `long-function`, `high-complexity`, `long-parameter-list` |
| Global state | `mutable-global-state` |
| Hygiene | `todo-hotspot`, `lint-suppression`, `commented-out-code`, `file-name-mismatch` |

With `--readiness`, the report also has a scorecard. See [`skills/flutter-agent-readiness/references/readiness-checks.md`](skills/flutter-agent-readiness/references/readiness-checks.md) for each check.

| Area | Checks |
|---|---|
| Agent experience | `instruction-file`, `task-commands`, `non-interactive-scripts`, `unguarded-dangerous-ops`, `fast-local-checks`, `honest-exit-codes`, `inconsistent-patterns`, `generated-noise` |
| Developer experience | `lint-config`, `format`, `ci-parity`, `setup-docs` |

The scorecard reads files and runs only `git ls-files`, `git check-ignore`, and `dart format --output=none`. It never runs tests, builds or setup steps, so it does not measure test speed or whether setup works. Like other readiness scores, it lists gaps in files and config; it does not predict how well an agent will do.

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
