# Readiness Checks

This file lists every check in the agent-readiness scorecard. Each entry says what the scanner checks, when it passes, warns or fails, the known false results, and the fix. Then it lists the judgment checks that Claude does by reading.

The scanner writes the scorecard to the `readiness` key of the report when it runs with `--readiness`. Each check has `id`, `area` (`ax` or `dx`), `status`, `summary`, `evidence`, `fix`, and sometimes `details`.

Statuses:

- `pass`: nothing to do.
- `warn`: a real gap, but agents can still work.
- `fail`: the thing is missing completely (no instruction file, no CI, no README, no lint config, no test file, committed build output).
- `unknown`: the scanner could not decide. Claude checks it by reading, or reports it as not checked.

The scorecard is a list of gaps, not a forecast. Readiness scores (this one, Factory's Agent Readiness, and others) measure inputs such as files and config. No published study links them to how well agents do. The only way to know whether a fix helps is to run an agent on real tasks before and after it (see "Measuring a fix" at the end).

"Visible to search" means tracked by git, or untracked and not ignored. ripgrep, which agent search tools use, sees the same set.

## Agent experience (AX)

### `instruction-file`
- Checks: `CLAUDE.md`, `.claude/CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.cursorrules`, `.github/copilot-instructions.md`, `.cursor/rules/*.md(c)` and `.github/instructions/*.md`. It follows `@path` imports (so a `CLAUDE.md` that only contains `@AGENTS.md` counts as AGENTS.md). It looks for 2 required sections by content: commands (a code block with `flutter`, `dart`, `make`, `./script` and similar) and rules or conventions (a heading such as "Rules", "Conventions", "Forbidden" or "Pitfalls", or 3 or more "never/always/must/avoid" bullets). A folder map is reported but not required: in the ETH Zurich study (arXiv 2602.11988), repository overviews did not help agents find the right files. What helped was what the agent cannot discover alone, such as non-standard tooling and conventions. It checks that every path in a code span (`` `scripts/x.sh` ``) and every `make X`, `melos run X` and `just X` exists.
- Fail: no instruction file. Warn: a missing section, a reference that does not exist, or more than 500 lines in total. Two studies found no effect of length on adherence, so the size warning is about upkeep and token cost: OpenAI's harness-engineering team found that one big AGENTS.md "rots instantly", and context files raised agent cost by over 20% in the ETH Zurich study. The fix is a short file that links to deeper docs in `docs/`.
- False results: placeholders (`<feature>`), globs (`*.g.dart`), suffixes (`_event.dart`), gitignored paths such as `.env`, and bare config names such as `pubspec.yaml` or `package_config.json` are skipped. Bare `.dart` and `.md` names are checked by file name anywhere in the repo. A path written relative to another folder (`../x/y.sh` in a root file) is reported as missing; it is ambiguous for agents too.
- Claude adds: pick 3 to 5 concrete rules (for example "never call `getIt` inside a Bloc") and check them against the code with Grep. A rule the code breaks in many places is worse than no rule, because the agent sees both.

### `task-commands`
- Checks: a command for test, analyze and format, plus code generation when a first-party package uses `build_runner`, and run when a first-party Flutter package has `lib/main*.dart`. It looks in the instruction files, README, Makefile, justfile, `melos.yaml`, `pubspec.yaml`, `Taskfile.yml`, `package.json`, and scripts directly in `scripts/` or `tool/`.
- Fail: neither test nor analyze is documented. Warn: any other task is missing.
- False results: a command in a wiki outside the repo does not count.

### `non-interactive-scripts`
- Checks: shell, Python, Ruby and Fastfile scripts, and Dart files in `bin/`, `tool/` or `scripts/`, for input prompts: `read` (not `while read` loops or pipes), `select`, `input()`, `getpass`, `click.confirm`, `UI.confirm`, `gets`, `stdin.readLineSync`. Test scripts and vendored packages are skipped.
- Warn: a script prompts and has no bypass. A bypass is a `--yes`, `-y`, `--no-input`, `--non-interactive` or `--force` flag, a `CI` environment check (`$CI`, `os.environ["CI"]`, `ENV["CI"]`, `is_ci`), or a terminal check (`isatty`, `[ -t 0 ]`).
- False results: a prompt behind an option the scanner does not know.
- Fix: add `--yes` and skip prompts when `CI` is set or stdin is not a terminal.

### `unguarded-dangerous-ops`
- Checks: the same scripts, Makefile targets and `melos.yaml`, for commands that ship or delete things: `firebase deploy`, `shorebird release|patch`, fastlane upload actions, `git push`, `git tag`, `gh release create`, `dart pub publish`, `kubectl`, `terraform apply|destroy`, `rm -rf /...`, `DROP TABLE`, and similar. Python list arguments (`["git", "push"]`) count.
- Warn: such a script has no guard. A guard is an input prompt, a `--dry-run` or `--confirm` option, or a `CI` environment check.
- Scripts under a `ci/` directory, or referenced from a CI file, are listed as "run by CI". They still warn, because an agent can run them locally, but the summary says CI is their normal caller. Rank them below unguarded local scripts.
- False results: a guard implemented in a helper the script calls.
- Fix: refuse to run unless `CI` is set or `--confirm` is passed, and add `--dry-run`.

### `fast-local-checks`
- Checks: a shared git hook config that runs format or analyze before a commit: `lefthook.yml`, `.pre-commit-config.yaml`, `.husky/`, `.githooks/`, `.git-hooks/`, `tool/hooks/` or `scripts/hooks/`, or a hook package in a pubspec (`git_hooks`, `husky`, `lefthook_dart`, `dart_pre_commit`). It follows scripts the hook calls one level deep. A hook that exists only in `.git/hooks/` is listed but does not count, because fresh clones do not get it.
- Warn: no shared hook, or a hook that runs neither format nor analyze.
- Why: every readiness checklist puts fast feedback first. Without a hook, "the agent waits ten minutes for CI feedback instead of five seconds" (Factory).
- False results: hooks installed by a tool the scanner does not know, or by `core.hooksPath` pointing at an unusual folder.

### `honest-exit-codes`
- Checks: shell scripts and Makefile recipes that run test, analyze, format or `flutter build`. A script warns when a check step is followed by `|| true`, piped (`| tee`) without `set -o pipefail`, or runs without `set -e`, without a status check (`if !`, `|| exit`, `$?`), and is not the last line. A Makefile recipe line warns with the `-` prefix or `|| true`.
- Warn: any such step.
- Why: a script that prints an error and exits 0 tells the agent the change works. "The agent then builds on a lie."
- False results: a step that may fail on purpose (for example, a report-only lint run). Ask for a comment, or move it out of the check path.

### `inconsistent-patterns`
- Checks: which library family each file uses for 6 concerns: state management, HTTP client (dio, http, chopper), dependency injection (get_it/injectable, kiwi, flutter_modular), routing (go_router, auto_route, beamer, fluro, routemaster, and imperative `Navigator.push`), serialization (json_serializable, dart_mappable, built_value, hand-written `fromJson`), and logging (logger, logging, talker, `dart:developer`, `print`/`debugPrint`). Vendored packages are skipped. `details` lists up to 20 files per family.
- Warn: a concern has 2 families, and the second-largest has 3 or more files. A family in 1 or 2 files is a leftover and is only listed in `details`. The count spans all first-party packages, so a separate CLI tool package can add a family. Check `details` and drop families that live only in a separate package.
- False results: a planned migration, or `http` used only for its types.
- Fix: name the one family per concern in the instruction file.

### `generated-noise`
- Checks: the share of Dart lines in generated files visible to search (`*.g.dart`, `*.freezed.dart`, `*.gr.dart`, `*.graphql.dart`, `__generated__/`, and others), whether `.ignore` or `.rgignore` hides them, visible files under `build/`, `coverage/` or `.dart_tool/`, data files over 1 MB, and vendored package copies.
- Fail: build output is visible to search (`build/` or `coverage/` directly in a package, or `.dart_tool/` anywhere; `lib/features/coverage/` does not count). Warn: generated code is 20% or more of Dart lines and no ignore file hides it, or a data file is over 1 MB.
- `analyzer: exclude` in `analysis_options.yaml` does not count. It hides files from the analyzer, not from search.
- Trade-off: an `.ignore` file also hides generated code from an agent that needs to read it (for example, to check a generated GraphQL selection). Agents can still pass `--no-ignore` or open the file directly. Say this when you recommend it.
- Vendored packages are found by a `homepage` or `repository` field in their pubspec, or a LICENSE without `publish_to: none`. Pub workspace members (`workspace:` in the root pubspec) and melos packages are always first-party. An in-house path package with a LICENSE can still be reported as vendored by mistake. Vendored packages are skipped by the other checks.

### `test-mapping`
- Checks: whether an agent that changes a `lib/` file can find a test for it. It counts first-party, hand-written `lib/` files that declare a class, mixin or function (parts, generated files and files with only constants are skipped). A file has a test when a test file in the same package is named after it (`foo.dart` and `foo_test.dart`, anywhere under `test/`) or a `*_test.dart` file imports it directly. Helpers and generated mocks under `test/` do not count. A test that reaches the file only through other files does not count either, because almost every file is reachable that way. This is how an agent finds the test for a file: by name, or by searching tests for the import. It is not coverage.
- Fail: no first-party package has a test file. Warn: fewer than 50% of the files have a test, or a first-party package with 10 or more such files has no test. Both numbers are conventions, not measured cut-offs.
- `details.untested` lists up to 30 files without a test, most changed first (commit counts from `git log`), or largest first outside git.
- Why: an agent checks its change by running the tests for the file it changed. With no test to find, it has no fast way to know the change works.
- False results: a test that covers a file through a barrel export or a shared helper is not counted. A test that imports a data class only to build a fixture, or an interface only to mock it, counts as a test for that file. An abstract interface with no test counts as untested.
- Fix: add tests for the most-changed untested files first, and name each test after its file.

### `unused-files`
- Checks: the import graph of all Dart files, built from `import`, `export` (including conditional imports) and `part` directives. Entry points are every Dart file outside `lib/` (tests, `bin/`, `tool/`, `example/`), every `lib/` file with a top-level `main`, and, in a package without a `main`, every `lib/` file outside `lib/src/`. A first-party, hand-written `lib/` file that no entry point reaches is unused. A file that only another unused file imports is unused too.
- Generated files are read from disk, even when they are gitignored, because aggregators such as `injection.config.dart` and `router.gr.dart` hold the only import of registered classes. When an imported generated file is missing (the build has not run), classes annotated `@injectable`, `@singleton`, `@lazySingleton`, `@module` or `@RoutePage` count as used, and the evidence says so.
- Warn: 1 or more unused files. Never fail. `details.testOnly` lists `lib/` files that only tests import; they do not change the status.
- Why: agents search the code. A dead file shows up in search results, costs context to read, and an agent may copy its pattern or fix a bug in it that no user can reach. Agents copy the patterns they find (OpenAI's harness-engineering team). The method is the usual unused-file analysis (DCM `check-unused-files`), not a readiness-source criterion.
- False results: a file loaded by a path in non-Dart config, by `dart run` from a script, or through a code generator the scanner does not know. Grep for the file name, including non-Dart files, before you report it. A barrel file (only `export` lines) that nothing imports is reported; it is dead, but deleting it changes nothing for users.
- Fix: delete the file, or import it where it was meant to be used.

### `co-change`
- Checks: the last 1000 non-merge commits (`git log --name-only`, read-only) for pairs of first-party `lib/` files that change together. Commits that change more than 30 such files are skipped, because they are usually renames or formatting. A pair counts when the files change together in 5 or more commits and in at least 50% of the commits that change either file (shared commits divided by the average of the two commit counts, as in Code Maat). A pair where one file imports, exports or includes the other is a visible link and is only counted in `details.linkedPairs`.
- Unknown: not a git repository, no commits, or fewer than 20 commits that change `lib/` files. Warn: 1 or more pairs with no import between them. Never fail. The thresholds are conventions, not measured cut-offs.
- `details.hiddenPairs` lists up to 20 pairs with `sharedCommits`, `coupling`, `sameDirectory`, and `importedTogetherBy` (hand-written files that import both).
- Why: an agent that changes one file of a hidden pair does not know the other must change, and nothing fails until a user finds the bug. This is the same idea as "if the agent cannot see it, it does not exist" in the readiness sources, applied to code instead of docs. The method itself comes from code forensics (change coupling in Code Maat), not from the readiness sources.
- Claude adds: open both files of each top pair and say what links them. Drop pairs the analyzer will guide the agent through: a repository interface and its data source, linked through the repository implementation in `importedTogetherBy`, are one layered change, and a compile error leads to the second file. Report duplicated code (two screens or widgets with copied blocks), copied constants, and protocols kept in sync by hand. These are the real hidden links.
- False results: two files that grow together because one feature is under active work, with no shared code.
- Fix: move the shared part into one file that both import. When the link must stay, write it down in the instruction file.

## Developer experience (DX)

### `lint-config`
- Checks: the root `analysis_options.yaml` and one in each first-party package, with their `include` chains. Package includes are read through the nearest `.dart_tool/package_config.json`, or through a local package with that name. It collects the enabled rules, the rules turned off (`false` or `errors: ignore`), analyzer plugins, and the `// ignore` comments in the code (vendored code skipped).
- Key lints, which set the status: `avoid_print`, and `use_build_context_synchronously` for configs that cover Flutter packages. Both are in stock `flutter_lints`, so a default project passes. Recommended lints, reported in the evidence only: `prefer_const_constructors` (stock `flutter_lints` 6 no longer enables it) and `unawaited_futures`.
- Fail: no `analysis_options.yaml` anywhere. Warn: a key lint is off, a package with Dart code has no config that applies to it, or there are more than 2 `// ignore` comments per 1000 lines. Unknown: an include cannot be read (usually because `pub get` has not run).
- False results: a project that turns a key lint off on purpose and says why in the file.

### `format`
- Checks: runs `dart format --output=none --set-exit-if-changed` on the hand-written Dart files (generated files, vendored packages, platform folders and examples are skipped). It writes nothing. When the project pins Flutter with FVM, it uses the pinned SDK's own `dart` binary from `.fvm/flutter_sdk`. Skip it with `--no-format`.
- Packages without a `.dart_tool/package_config.json` are skipped and listed. Without it, `dart format` assumes the newest language version, and a project older than Dart 3.7 would look completely unformatted.
- Unknown: the project pins a version that is not installed, no package has a package config, or the formatter failed. Warn: some files are not formatted. Fail: more than 10%.
- Why it matters for agents: an agent that formats the file it edits adds unrelated lines to the diff.

### `ci-parity`
- Checks: GitHub workflows and local actions, Codemagic, Bitrise, GitLab, Azure, CircleCI, Jenkins, Bitbucket, Travis and AppVeyor config. Commented-out lines are skipped. It follows scripts that CI runs one level deep. A script named for a task (`test_bundled.sh`, `run_tests.sh`, `lint.sh`, `format.sh`) counts as that task, because scripts often start Flutter through a variable.
- Fail: no CI config. Warn: CI does not run analyze, test or format. Also warn when CI and the documented commands for one task share no command, or when CI uses `--fatal-infos` and the documented analyze command does not.
- False results: CI that calls a task through a tool the scanner does not know (a custom Docker image, a Gradle task).

### `setup-docs`
- Checks: the README, `docs/*.md` and the instruction files, for headings about setup, environment, architecture and release. A `docs/` file named for architecture or release also counts. It checks for a pinned Flutter version (`.fvmrc`, `.fvm/fvm_config.json`, `.tool-versions`, `mise.toml`, `.puro.json`, or `environment: flutter:` in the pubspec), and for an env template (`.env.example` and similar) when the app depends on `flutter_dotenv`, `envied`, `dotenv` or `flutter_config`, or lists `.env` as an asset.
- Environment docs and a pinned Flutter version are required only when a first-party package depends on Flutter (environment docs also when the code reads `.env`). A pure Dart tool needs only setup, architecture and release docs.
- Fail: no README. Warn: any missing part.
- Claude adds: the scanner cannot tell whether the setup steps work. Say so under "Not checked".

## Judgment checks (Claude reads)

| Check | What to look for |
|---|---|
| Rules the code breaks | Sample 3 to 5 concrete rules from the instruction file and Grep for violations. For each rule, say whether a lint, analyzer plugin, test or CI step enforces it, or whether it is written down only. "If a rule matters, a machine checks it": a doc-only rule drifts, and a lint can carry its fix in the error message |
| Error messages | Read 5 to 10 `throw`, `Failure(...)` and script `echo ... >&2` sites. A good message says what failed, lists the valid values or the nearest match, says what to do next, and does not dump a stack trace by default. Agents arrive with a plan, so a message that names the wrong approach works better than a hint about the right one |
| Hidden behaviour | Code that runs because of file location, reflection, `noSuchMethod`, implicit config, or build-time magic not explained in the instruction file |
| Misleading names | Beyond `file-name-mismatch`: classes or methods whose name says something other than what they do, in the hotspot files |
| Dead code | `unused-files` covers whole files. Add the `commented-out-code` findings, and DCM `check-unused-code` for unused classes and functions if it is installed. Otherwise report unused symbols as not checked |
| Slow feedback loop | Not measured. Static signs only: does the default test command also run `integration_test/`? Is there a way to run one test file? |
| Context cost of large files | Not a separate check. Report the `long-file` count from `summary.bySmell` and the largest files, because an agent reads whole files |
| Runtime visibility | Can an agent run the app and see what happens? Look for a documented `flutter run` target, integration or Maestro tests, and readable logs. Report what is missing |

## Measuring a fix

To learn whether a fix really helps, use Microsoft's DevAX loop on a small scale:

1. Write 3 to 5 tasks the team really gives agents, in their own words.
2. Run each task 3 to 5 times with the same harness and model, before the fix.
3. Make the fix and run the same tasks again.
4. Compare a strict pass rate (every requirement met) and the token cost. A fix that raises cost without raising the pass rate is not a fix.

Several fixes that sound agent-friendly measured as neutral or worse (for example, adding an llms.txt or an extra documentation MCP server). Measure before you recommend a large change.
