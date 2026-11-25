---
name: flutter-agent-readiness
description: Audit how ready a Flutter or Dart repository is for AI coding agents (Claude Code, Codex, Copilot, Cursor) and return a pass/warn/fail scorecard with evidence and a fix for each gap. A bundled read-only scanner checks the instruction files (CLAUDE.md, AGENTS.md and others, including broken paths), documented commands, interactive and unguarded deploy scripts, pre-commit hooks, scripts that hide failures behind exit code 0, inconsistent library patterns, generated-code noise, files without a test, unused files, hidden git co-change, lint config, formatting, CI parity, and setup docs; Claude then checks whether the instruction rules are enforced and followed, and reads for what a scanner cannot see. Use this whenever the user asks if a repo is "agent ready" or "AI ready", to audit or improve a CLAUDE.md or AGENTS.md, why agents struggle in a codebase, how to make a Flutter repo easier for Claude to work in, or for an AX or DX audit, even if they don't say "readiness". Not for a code-smell list (use flutter-smell-scan), for writing a CLAUDE.md from scratch (use init), or for non-Dart repos.
---

# Flutter Agent Readiness

Find out what makes a Flutter or Dart repository hard for an AI agent to work in, and report it as a short scorecard with the fix for each gap.

The scanner in the `flutter-smell-scan` skill does the measuring. It checks files and config, so its results are the same on every run. Claude then checks what needs judgment: whether the code follows the instruction file, whether error messages help, and whether anything runs by magic.

Write the report in the voice defined in `~/.claude/rules/writing-voice.md` if that file exists. Otherwise write short, plain English: the answer first, one idea per sentence.

## Rules

- **The scan is read-only.** Never edit, format, or `pub get` the target project during the audit. The scanner only reads files, runs `git ls-files`, `git check-ignore`, `git log`, and `dart format --output=none`, which writes nothing. If the user wants fixes, finish the report first, then ask.
- **Read the report file, not stdout.** The scanner prints a short summary only. Read the JSON with the Read tool or `jq`. Shell output filters (such as rtk) can shorten output and change counts.
- **Check before you report.** For every `warn` and `fail`, open at least one evidence path and confirm it. Drop a result you cannot confirm, and say how many you dropped.
- **No score.** Report pass, warn, fail and unknown counts. Do not invent a total number.

## Workflow

### 1. Run the scanner

```bash
bash <skills-dir>/flutter-smell-scan/scripts/scan.sh <project-dir> --readiness --out <scratch-dir>/readiness.json
```

- `<skills-dir>` is the parent of the directory that holds this SKILL.md. The scanner lives in the sibling `flutter-smell-scan` skill.
- Put the report in the session scratchpad or the system temp directory, never inside the project.
- Add `--no-analyze` to skip `dart analyze` (much faster). Add `--no-format` to skip the format check.
- The same report also holds the code-smell findings. Use them only where they support a readiness result (for example, `commented-out-code` for dead code). For a full smell report, use the `flutter-smell-scan` skill.

### 2. Confirm the scanner results

Read `readiness.checks`. `references/readiness-checks.md` says what each check measures and its known false results. Read it before this step.

1. For each `fail` and `warn`, open the evidence paths and confirm the problem. Fix the status in your report if the scanner was wrong.
2. For each `unknown`, try to decide by reading (for example, read the lint include by hand). If you cannot, put it under "Not checked".
3. `readiness.vendoredPackages` lists package copies the scanner treats as third-party. If one is first-party, say so.

### 3. Do the judgment checks

Do these in order. Stop at about 15 tool calls in total.

1. **Rules against code.** Pick 3 to 5 concrete, checkable rules from the instruction file. Grep for violations. Report each broken rule with a count and 1 or 2 `file:line` examples. For each rule, also say whether a lint, analyzer plugin, test or CI step enforces it, or whether it is only written down. A rule that matters should be checked by a machine.
2. **Error messages.** Read 5 to 10 `throw`, `Failure(...)` and script error sites in the main code. A good message says what failed, lists the valid values or the next step, and has no default stack trace. Report vague ones with `file:line`.
3. **Hidden behaviour.** Look for code that runs because of file location, reflection, `noSuchMethod`, or implicit config that the instruction file does not explain.
4. **Dead code.** `unused-files` covers whole files. Add the `commented-out-code` findings. If `dcm` is on PATH, run `dcm check-unused-code <dir>` for unused classes and functions.
5. **Hidden links.** Read all of `co-change` `details.hiddenPairs`. Drop layered pairs: an interface and its data source that a repository implementation in `importedTogetherBy` imports. Open both files of the top 3 pairs that remain, and of any pair with an empty `importedTogetherBy`, and say what links them. Report duplicated code and values kept in sync by hand.
6. **Large files.** Report the `long-file` count from `summary.bySmell` and the 3 largest files, because an agent reads whole files into its context.

### 4. Write the report

Use this shape. Keep it short enough to read in two minutes.

```markdown
**Verdict:** <one or two sentences: how ready the repo is, and the single most useful fix>

Scorecard: <P> pass, <W> warn, <F> fail, <U> unknown. Checked <date>.

| Check | Status | Evidence |
|---|---|---|
| instruction-file | pass/warn/fail | <one line, with a path> |
| ... | | |

## Fix first
1. **<check or judgment finding>**: <what is wrong, with evidence>. <Why it slows or misleads an agent>. <The concrete fix>.
2. ...

## Rules the code breaks
- "<rule>" (<instruction file>, <enforced by X | doc only>): <count> places, e.g. `file:line`.

## Not checked
<Slow tests or builds, whether setup steps work, anything unknown, and anything you skipped. Say that the scorecard lists gaps; it does not predict how well agents will do.>
```

"Fix first" holds at most 5 items. Rank by how often an agent hits the problem: unguarded dangerous scripts and broken feedback (`honest-exit-codes`, a missing or broken instruction file) come first, then missing commands and slow feedback (`fast-local-checks`, `test-mapping`), then doc-only rules the code breaks and confirmed `co-change` pairs, then inconsistent patterns, unused files and noise, then DX gaps.

After the report, offer the next step in one line: fix the top items (for example, draft the missing AGENTS.md sections or a lefthook config), measure one fix with the loop in `references/readiness-checks.md`, or run `flutter-smell-scan` for code-level smells.

## Reference

- `references/readiness-checks.md`: every check, its pass/warn/fail rules, known false results, and the fix. Read it before step 2.
- `../flutter-smell-scan/scripts/`: the scanner. `dart test` inside it runs its tests.
