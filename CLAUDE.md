# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Claude Code plugin with one skill, `flutter-smell-scan`. The repo root is both the plugin and its own marketplace (`.claude-plugin/marketplace.json` points `source` at `./`).

The skill has two halves:

- `skills/flutter-smell-scan/scripts/`: a Dart package (`smell_scan`) that parses a Flutter/Dart project with `package:analyzer` and writes one JSON report of metric-based smells.
- `skills/flutter-smell-scan/SKILL.md`: instructions that tell Claude how to run the scanner, verify `high` findings against the source, read hotspot files for judgment smells, and write a ranked report.

## Commands

All Dart commands run inside `skills/flutter-smell-scan/scripts/` and need Dart 3.8 or later.

```bash
cd skills/flutter-smell-scan/scripts
dart pub get
dart analyze
dart test                                   # all tests
dart test --plain-name "missing-dispose"    # tests whose name contains the string
```

Run the scanner on a project (the first run resolves the scanner's own packages):

```bash
skills/flutter-smell-scan/scripts/scan.sh <project-dir> --out /tmp/smell-report.json
skills/flutter-smell-scan/scripts/scan.sh <project-dir> --no-analyze --set long-function=40
```

Load the plugin from this checkout without installing it: `claude --plugin-dir .`

## Scanner architecture

The flow is `scan.sh` → `bin/smell_scan.dart` → `scanProject()` in `lib/src/project_scanner.dart` → `FileScanner` in `lib/src/file_scanner.dart`.

- `bin/smell_scan.dart` parses CLI options, refuses an `--out` path inside the scanned project, writes the JSON report, and prints only a 3-line summary. Exit codes follow sysexits: 64 for bad usage, 66 for a missing directory.
- `scanProject()` walks the tree, skips hidden dirs, `build/`, platform folders next to a `pubspec.yaml`, test dirs (unless `--include-tests`), and generated files (by suffix or by a generated-code header). It parses each file with `parseString` and runs one `FileScanner` per file. It then adds project-level findings (such as `mixed-state-management`), ranks hotspot files by score, and runs `dart analyze` only for packages that already have a `package_config.json`.
- `FileScanner` holds all per-file detectors. Each detector is a method or a private `RecursiveAstVisitor` (complexity, widget depth, catch clauses, data calls, release calls).
- `lib/src/model.dart` holds `Finding`, `Severity`, and `Thresholds.defaults`, the single source of threshold keys that `--set` accepts.

## Rules that the design depends on

- **The scanner is read-only.** It never runs `pub get` in, formats, or writes to the scanned project. `scanProject` has a test that checks this. Keep it true.
- **Parsing is unresolved.** There is no type information. Widgets are found by their `build(BuildContext)` method and types by name. New detectors must work on syntax alone, and their false positives belong in the catalog.
- **Metric severity:** `medium` when a value passes its threshold, `high` at twice the threshold.

## Keep these in sync

When you add or change a smell, update all of these:

1. The detector in `file_scanner.dart` (or `project_scanner.dart` for project-level smells).
2. The threshold key in `Thresholds.defaults`, if the smell has one.
3. `references/smell-catalog.md`: what it measures, why it matters, known false positives, and the fix. `SKILL.md` relies on this file for triage.
4. The "What it detects" table in `README.md`.
5. A test in `test/scanner_test.dart`. Tests use the `scan(code, ...)` helper, which parses a code string and returns the findings.

The version string appears in four places: `toolVersion` in `project_scanner.dart`, `scripts/pubspec.yaml`, `.claude-plugin/plugin.json`, and `.claude-plugin/marketplace.json` (twice). Bump them together.
