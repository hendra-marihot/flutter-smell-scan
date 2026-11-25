# Smell Catalog

This file lists every smell the scanner reports, then the judgment smells that Claude finds by reading code. Each entry says what is measured, why it matters, the known false positives, and the usual fix.

Severity rules for metric smells: `medium` when the value passes the threshold, and `high` at twice the threshold. Override any threshold with `--set key=value`.

## Scanner smells

### Lifecycle and errors (fix these first)

**`missing-dispose`** (high for timers, subscriptions, stream and animation controllers; medium for notifiers, text and scroll controllers, and focus nodes; low when only mentioned in `dispose()`)
- Measures: a `State` or `ConsumerState` class field whose type needs releasing (`TextEditingController`, `AnimationController`, `ScrollController`, `PageController`, `TabController`, `FocusNode`, `StreamSubscription`, `StreamController`, `Timer`, `ValueNotifier`, and similar) that `dispose()` never calls `dispose()`, `cancel()` or `close()` on. Cascades (`_c..removeListener(f)..dispose()`) and `this._c` count as released.
- Why: the object outlives the screen. Timers and subscriptions keep firing, and controllers keep their listeners and memory.
- False positives: the field is released in a helper method that `dispose()` calls, or in a loop (`low` severity covers the loop case). The field is passed in from outside and owned by someone else.
- Fix: release it in `dispose()` before `super.dispose()`.

**`listener-not-removed`** (low)
- Measures: a `State` class calls `addListener()` and never calls `removeListener()`, and the listenable is not a field the class disposes.
- Why: if the listenable lives longer than the widget, it keeps a reference to a disposed `State` and calls `setState` on it.
- False positives: the class creates the listenable locally and disposes it through another name (common with camera or video controllers).
- Fix: keep a reference to the callback and remove it in `dispose()`.

**`swallowed-exception`** (medium when empty, low when it only prints)
- Measures: a `catch` block with no statements and no comment, or one that only calls `print`, `debugPrint` or `log`. Empty blocks that contain an explaining comment are skipped as deliberate.
- Why: the failure disappears. The user sees no error, and the bug report has no stack trace.
- False positives: best-effort code such as analytics, where ignoring the error is correct but undocumented. Ask for a comment instead of a rewrite.
- Fix: rethrow, map the error to a failure type the caller handles, or report it to crash logging.

### Layering

**`ui-layer-leak`** (medium; low for presentation files that import `data/`)
- Measures: a file that declares a widget imports a data-layer package (`dio`, `http`, `shared_preferences`, `sqflite`, `drift`, `hive`, `isar`, `cloud_firestore`, `graphql`, `flutter_secure_storage`, ...). Or a widget calls `jsonDecode`, `Dio()`, `http.get`, `SharedPreferences.getInstance` and similar itself. Or a file under `presentation/`, `ui/`, `screens/`, `pages/` or `widgets/` imports a path that contains `data/`.
- Why: the widget cannot be tested without the network or disk, and the same call gets copied into other screens.
- False positives: a widget that only uses a type from the package (for example `http` for an image header). A small app with no layers on purpose.
- Fix: move the call into a repository and expose it through the state holder.

**`mixed-state-management`** (medium, project level, `file` is `(project)`)
- Measures: the project imports two or more state-management families (bloc, provider, riverpod, getx, mobx, redux, signals). `stateManagement.families` lists the files for each.
- Why: every new developer has to learn several patterns, and loading and error handling become inconsistent between features.
- False positives: a planned migration in progress, or a family used once by a third-party widget. Check the file counts: 40 files against 2 files is a leftover, not a split.
- Fix: pick one, write it down, and migrate the minority side when those files are next touched.

### Flutter structure

**`widget-helper-method`** (medium over 20 lines, else low)
- Measures: a non-static method in a widget or `State` class that returns `Widget` (or `PreferredSizeWidget`, and so on) and is not `build()`. Same idea as DCM's `avoid-returning-widgets`.
- Why: Flutter cannot rebuild a method on its own or make it `const`. Every rebuild of the parent rebuilds the whole subtree, and the method cannot be reused or tested alone.
- False positives: tiny one-line helpers that read cleaner as methods. The count matters more than any single one.
- Fix: extract a `StatelessWidget` class and pass in only the data it needs.

**`deep-widget-nesting`** (approximate)
- Measures: the depth of nested capitalised constructor calls in `build()`. The line points at the deepest call. It also counts non-widget calls such as `TextStyle(...)` or `EdgeInsets.all(...)`, so treat the number as a rough guide. Threshold `deep-widget-nesting`, default 12.
- Why: deep trees are hard to read and usually hide 2 or 3 widgets that should have names.
- Fix: extract the inner subtrees into named widget classes.

**`long-build-method`**
- Measures: lines in `build()`. Threshold `long-build-method`, default 100.
- Fix: extract sections into widget classes, not helper methods.

**`setstate-heavy`**
- Measures: `setState()` calls in one `State` class. Threshold `setstate-heavy`, default 8.
- Why: many `setState` calls usually mean the widget holds business state and logic, not just UI state.
- Fix: move the state into the project's state holder (Cubit, Notifier, ...).

**`oversized-state-holder`**
- Measures: a Bloc, Cubit, ChangeNotifier, StateNotifier, Notifier, GetxController, or `*ViewModel` class over `state-holder-lines` (default 250) lines or with more than `state-holder-methods` (default 12) public methods.
- Why: one state holder serving many screens or concerns. Changes conflict, and tests have to set up everything.
- Fix: split it by user task or by screen.

### Size and complexity

**`long-file`**: physical lines in one file. Threshold `long-file`, default 500 (DCM's default). Generated files are skipped.

**`large-class`**: lines in one class that is not a state holder. Threshold `large-class`, default 300.

**`long-function`**: lines in one function or method, `build()` excluded. Threshold `long-function`, default 50.

**`high-complexity`**: cyclomatic complexity. It counts 1, plus 1 for each `if`, collection `if`, `for`, `while`, `do`, `catch`, `?:`, switch case, `&&`, `||` and `??`. Threshold `high-complexity`, default 20. A `build()` with high complexity usually has many conditional branches that should become separate widgets or state values.

**`long-parameter-list`**: parameters in a function or method. For constructors, only positional parameters count, because named parameters are the normal Dart style for data classes and widgets. Redirecting factories (freezed) are skipped. Threshold `long-parameter-list`, default 5. Fix: group related parameters into a value object.

## Judgment smells (found by reading)

The scanner cannot see these. Look for them in the hotspot files.

| Smell | What to look for | Why it hurts |
|---|---|---|
| Business rules in widgets | Validation, price or fee calculation, or eligibility checks inside `build()` or `onPressed` | Cannot be unit-tested, and gets duplicated across screens |
| Context in state holders | A Cubit or Notifier that takes `BuildContext`, calls `Navigator`, or shows dialogs | Ties logic to the widget tree. Breaks after `await` and in tests |
| `double` for money | Amounts stored or calculated as `double` | Rounding errors in payments and totals. Use integer minor units or a decimal type |
| Cross-feature imports | `features/a/...` imports `features/b/presentation/...` or `features/b/data/...` | Features cannot change or be removed alone |
| Service locator in widgets | `GetIt.I<Repo>()` or `getIt<...>()` inside `build()` | Hidden dependencies, and hard to replace in widget tests |
| Stringly-typed state | Status held as `String` or `int` codes compared in many places | Typos compile. Use an enum or a sealed class |
| Copy-paste screens | Two screens or widgets with nearly the same tree | Fixes land in one copy only. DCM `check-code-duplication` finds these |
| Hard-coded design values | Raw `Color(0xFF...)`, font sizes, or paddings instead of theme tokens | The design system drifts, and dark mode breaks |
| Async gaps | `context` used after `await` without a `mounted` check | Crashes or acts on a disposed screen. The analyzer lint `use_build_context_synchronously` catches most of these when it is enabled |
| Silent nullable fallbacks | `?? ''`, `?? 0` or `!` on data that must exist | Hides missing data until it reaches the user |

## What this scan does not cover

- Duplicated code (use DCM `check-code-duplication` if available).
- Unused code and unused files (DCM `check-unused-code`, `check-unused-files`).
- Runtime performance, such as rebuild counts and jank (use Flutter DevTools).
- Test quality and coverage.
- Code that only appears through code generation.
