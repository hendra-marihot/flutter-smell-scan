---
name: flutter-smell-scan
description: Scan a Flutter or Dart codebase for code smells and return a ranked, verified list with file:line for each finding. A bundled read-only scanner measures size, complexity, nesting, widget-helper methods, undisposed controllers, swallowed exceptions, data calls inside widgets, and mixed state management; Claude then checks the high findings against the source and reads the worst files for smells a metric cannot see. Use this whenever the user asks to find code smells, scan or audit a Flutter/Dart project's code quality, find refactoring hotspots, "what is wrong with this codebase", "where should we refactor first", or to check a project they just inherited, even if they don't say "smell". Also use it to scan only the files a branch changed. Not for line-by-line PR comments (use a PR review skill), for planning and costing tech-debt work (tech-debt-assessment), for carrying out a refactor (refactor), or for system-level architecture decisions (architecture-review).
---

# Flutter Smell Scan

Find code smells in a Flutter or Dart project, verify them, and report them ranked by how much they hurt.

The work has two halves. A deterministic scanner measures what metrics can measure, so the counts and line numbers are exact and the same on every run. Claude then does what the scanner cannot: it drops false positives, and it reads the worst files for smells that need judgment.

Write the report in the voice defined in `~/.claude/rules/writing-voice.md` if that file exists. Otherwise write short, plain English: the answer first, one idea per sentence.

## Rules

- **The scan is read-only.** Never edit, format, or `pub get` the target project during a scan. The scanner refuses to write its report inside the project. If the user wants fixes, finish the report first, then ask.
- **Read the report file, not stdout.** The scanner prints only a short summary. Read the JSON report with the Read tool or `jq`. Shell output filters (such as rtk) can shorten long output and change counts and line numbers.
- **Verify before you report.** Open the source at `file:line` for every `high` finding you put in the report. Never report a finding you did not check, unless you label it unverified.

## Workflow

### 1. Run the scanner

```bash
bash <skill-dir>/scripts/scan.sh <project-dir> --out <scratch-dir>/smell-report.json
```

- `<skill-dir>` is the directory that holds this SKILL.md.
- Put the report in the session scratchpad or the system temp directory, never inside the project.
- The first run resolves the scanner's own Dart packages (about 10 seconds). It needs `dart` on PATH and never touches the target's packages.
- Useful options: `--include-tests` also scans `test/`. `--no-analyze` skips `dart analyze`, which saves most of the run time on large projects. `--set long-function=40` overrides a threshold. `--help` lists all of them.
- A monorepo works as one scan. The report marks each package's path.

On a 180k-line project the scan takes about 80 seconds with the analyzer and under 10 seconds without it.

### 2. Check the analyzer status

Look at `analyzer.status` in the report.

- `ok`: the report includes the project's own `dart analyze` diagnostics (its lint rules from `analysis_options.yaml`). Fold the relevant ones into the smells (for example `use_build_context_synchronously`, `avoid_print`).
- `skipped` with `unresolvedPackages`: the project has never had `pub get`, so the analyzer would only report unresolved imports. Tell the user. Ask before you run `flutter pub get` there, because it writes `.dart_tool/` and can change `pubspec.lock`. The scanner's own detectors work without it.

### 3. Triage the findings

Read `summary.bySmell`, `hotspots`, and `findings`. Each finding has `smell`, `severity`, `file`, `line`, `symbol`, `value`, `threshold`, and `message`.

1. Open every `high` finding at `file:line` and decide: real, or false positive. `references/smell-catalog.md` lists the known false positives for each smell. Drop the false positives, and count them.
2. For each smell type with many `medium` findings, open 2 or 3 of them. If they are real, report the type as a pattern with the count, and list the worst examples. Do not list 100 near-identical findings.
3. Treat `low` findings as background. Mention them only as counts, unless one is clearly worse than its severity says.
4. Skip vendored code (for example a `packages/<third_party_fork>/` directory) unless the user owns it. Say that you skipped it.

### 4. Read the hotspots for judgment smells

Read the top 3 to 5 files in `hotspots` in full. Look for the judgment smells in `references/smell-catalog.md` that no metric catches: business rules in widgets, a state holder that knows about navigation or `BuildContext`, `double` used for money, one feature importing another feature's internals, and so on. Report them with `file:line`, like scanner findings, and mark them as found by reading.

### 5. Optional: DCM

If `dcm` is on PATH (check with `command -v dcm`), DCM can add checks this scanner does not have. On the Free plan, `dcm check-unused-files <dir>` finds files nothing imports. On Pro and above, `dcm check-unused-code`, `dcm check-code-duplication` and `dcm analyze-widgets` find unused code, duplicated code, and poor-quality widgets. Run them only when installed, and do not ask the user to buy a licence.

### 6. Write the report

Use this shape. Keep it short enough to read in two minutes.

```markdown
**Verdict:** <one or two sentences: overall health and the single most important fix>

Scanned <N> files (<L> lines), <date>. Analyzer: <ok | skipped, reason>.
Dropped <K> false positives after checking the source.

## Fix first
1. **<smell> at `path/file.dart:123`** (`Symbol`): <what is wrong, with the measured value>. <Why it hurts>. <The concrete fix>.
2. ...

## Patterns
- **<smell>**: <count> places, worst at `file:line`, `file:line`. <One-line fix pattern>.

## Hotspot files
| File | Lines | Main problems |
|---|---|---|

## Not checked
<What this scan cannot see: duplication without DCM, runtime behaviour, test quality, and anything you skipped.>
```

"Fix first" holds at most 5 items: the verified findings that cost the most (leaks, swallowed errors and layer leaks come before size metrics). Each item names the fix, not only the problem.

After the report, offer the next step in one line: fix the top items, save the report as a file, or scan again with changed thresholds.

## Scanning only a branch's changes

To scan a PR or branch, run the full scan, then keep only the findings whose `file` is in `git diff --name-only <base>...HEAD`. Project-level findings such as `mixed-state-management` stay only when the branch adds the second library.

## Reference

- `references/smell-catalog.md`: every smell id, what it measures, its known false positives, and the usual fix. Read it before step 3.
- `scripts/`: the scanner (a Dart package). `dart test` inside it runs its unit tests.
