import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;
import 'package:smell_scan/smell_scan.dart';
import 'package:test/test.dart';

List<Finding> scan(
  String code, {
  String path = 'lib/a.dart',
  Map<String, int> t = const {},
}) {
  final parsed = parseString(content: code, throwIfDiagnostics: false);
  return FileScanner(
    path: path,
    unit: parsed.unit,
    content: code,
    t: Thresholds(t),
  ).scan().findings;
}

Iterable<Finding> of(List<Finding> fs, String smell) =>
    fs.where((f) => f.smell == smell);

void main() {
  group('missing-dispose', () {
    test('flags a controller that dispose() never releases', () {
      final fs = scan('''
class _S extends State<W> {
  final _name = TextEditingController();
  final ScrollController _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => Text('x');
}
''');
      final hits = of(fs, 'missing-dispose').toList();
      expect(hits, hasLength(1));
      expect(hits.single.symbol, '_S._name');
      expect(hits.single.line, 2);
      // A TextEditingController leak costs memory only.
      expect(hits.single.severity, Severity.medium);
    });

    test('flags every disposable when dispose() is missing', () {
      final fs = scan('''
class _S extends State<W> {
  late final AnimationController _a;
  StreamSubscription<int>? _sub;
  Widget build(BuildContext context) => Text('x');
}
''');
      expect(of(fs, 'missing-dispose').map((f) => f.symbol), [
        '_S._a',
        '_S._sub',
      ]);
      expect(
        of(fs, 'missing-dispose').map((f) => f.severity).toSet(),
        {Severity.high},
      );
    });

    test('accepts cascades and this.-qualified receivers', () {
      final fs = scan('''
class _S extends State<W> {
  late final _tabs = TabController(length: 2, vsync: this);
  final _focus = FocusNode();
  void dispose() {
    _tabs
      ..removeListener(_on)
      ..dispose();
    this._focus.dispose();
    super.dispose();
  }
  Widget build(BuildContext context) => Text('x');
}
''');
      expect(of(fs, 'missing-dispose'), isEmpty);
    });

    test('field mentioned in dispose() but not released is low', () {
      final fs = scan('''
class _S extends State<W> {
  final _a = FocusNode();
  void dispose() { for (final n in [_a]) { n.dispose(); } super.dispose(); }
  Widget build(BuildContext context) => Text('x');
}
''');
      expect(of(fs, 'missing-dispose').single.severity, Severity.low);
    });

    test('accepts cancel() and null-aware calls', () {
      final fs = scan('''
class _S extends State<W> {
  Timer? _timer;
  StreamSubscription<int>? _sub;
  void dispose() { _timer?.cancel(); _sub!.cancel(); super.dispose(); }
  Widget build(BuildContext context) => Text('x');
}
''');
      expect(of(fs, 'missing-dispose'), isEmpty);
    });
  });

  test('widget-helper-method flags Widget-returning methods in UI classes', () {
    final fs = scan('''
class Card1 extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [_buildHeader()]);
  Widget _buildHeader() => Text('h');
  PreferredSizeWidget _appBar() => AppBar();
  static Widget helper() => Text('s');
  String label() => 'x';
}
class NotUi { Widget make() => Text('x'); }
''');
    expect(of(fs, 'widget-helper-method').map((f) => f.symbol), [
      'Card1._buildHeader',
      'Card1._appBar',
    ]);
  });

  test('ui-layer-leak flags data packages and direct calls in widgets', () {
    final fs = scan('''
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
class P extends StatelessWidget {
  Widget build(BuildContext context) {
    final r = Dio().get('/x');
    final m = jsonDecode('{}');
    return Text('x');
  }
}
''');
    final hits = of(fs, 'ui-layer-leak').toList();
    expect(hits.map((f) => f.line).toSet(), {1, 5});
    expect(hits.firstWhere((f) => f.line == 5).value, 2);
  });

  test('presentation file importing data layer is a low leak', () {
    final fs = scan('''
import '../../data/repo_impl.dart';
class P extends StatelessWidget {
  Widget build(BuildContext context) => Text('x');
}
''', path: 'lib/features/x/presentation/p.dart');
    final hits = of(fs, 'ui-layer-leak').toList();
    expect(hits.single.severity, Severity.low);
  });

  test('swallowed-exception: empty is medium, print-only is low', () {
    final fs = scan('''
void a() { try { x(); } catch (_) {} }
void b() { try { x(); } catch (e) { print(e); } }
void c() { try { x(); } catch (e) { rethrow; } }
void d() {
  try { x(); } catch (_) {
    // Analytics must never break the caller.
  }
}
''');
    expect(of(fs, 'swallowed-exception').map((f) => f.severity), [
      Severity.medium,
      Severity.low,
    ]);
  });

  test('long-parameter-list counts positional constructor params only', () {
    final fs = scan('''
class A {
  A(this.a, this.b, this.c, this.d, this.e, this.f);
  A.named({int? a, int? b, int? c, int? d, int? e, int? f});
  A.positional(int a, int b, int c, int d, int e, int f);
  factory A.data({int? a, int? b, int? c, int? d, int? e, int? f}) = _A;
  final int a, b, c, d, e, f;
  void m(int a, int b, int c, int d, int e, int f) {}
}
''');
    expect(of(fs, 'long-parameter-list').map((f) => f.symbol), [
      'A.positional',
      'A.m',
    ]);
  });

  test('listener on a field the State owns and disposes is not flagged', () {
    final fs = scan('''
class _S extends State<W> {
  final _scroll = ScrollController();
  void initState() { _scroll.addListener(_on); }
  void dispose() { _scroll.dispose(); super.dispose(); }
  Widget build(BuildContext context) => Text('x');
}
''');
    expect(of(fs, 'listener-not-removed'), isEmpty);
  });

  test('high-complexity counts branches and boolean operators', () {
    final body = List.generate(6, (i) => 'if (a == $i && b) {}').join('\n');
    final fs = scan('void f(int a, bool b) {\n$body\n}', t: {
      'high-complexity': 10,
    });
    final hit = of(fs, 'high-complexity').single;
    expect(hit.value, 13); // 1 + 6 ifs + 6 &&
  });

  test('oversized-state-holder uses method count for Cubits', () {
    final methods = List.generate(4, (i) => 'void m$i() {}').join('\n');
    final fs = scan('class C extends Cubit<int> {\n$methods\n}', t: {
      'state-holder-methods': 3,
    });
    final hit = of(fs, 'oversized-state-holder').single;
    expect(hit.value, 4);
    expect(of(fs, 'large-class'), isEmpty);
  });

  test('setstate-heavy and listener-not-removed', () {
    final calls = List.generate(3, (_) => 'setState(() {});').join('\n');
    final fs = scan('''
class _S extends State<W> {
  void initState() { widget.notifier.addListener(_on); }
  void _on() { $calls }
  Widget build(BuildContext context) => Text('x');
}
''', t: {'setstate-heavy': 2});
    expect(of(fs, 'setstate-heavy').single.value, 3);
    expect(of(fs, 'listener-not-removed').single.line, 2);
  });

  test('deep-widget-nesting reports the deepest line', () {
    var tree = "Text('leaf')";
    for (var i = 0; i < 5; i++) {
      tree = 'Padding(\n child: $tree)';
    }
    final fs = scan('''
class W extends StatelessWidget {
  Widget build(BuildContext context) {
    return $tree;
  }
}
''', t: {'deep-widget-nesting': 4});
    final hit = of(fs, 'deep-widget-nesting').single;
    expect(hit.value, 6);
    expect(hit.line, 8);
  });

  test('scanProject is read-only and finds mixed state management', () async {
    final dir = await Directory.systemTemp.createTemp('smell_scan_test');
    addTearDown(() => dir.delete(recursive: true));
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: x\n');
    final lib = Directory(p.join(dir.path, 'lib'))..createSync();
    File(p.join(lib.path, 'a.dart')).writeAsStringSync(
      "import 'package:flutter_bloc/flutter_bloc.dart';\n",
    );
    File(p.join(lib.path, 'b.dart')).writeAsStringSync(
      "import 'package:provider/provider.dart';\n",
    );
    File(p.join(lib.path, 'b.g.dart')).writeAsStringSync('void f() {}\n');

    final before = dir
        .listSync(recursive: true)
        .map((e) => e.path)
        .toSet();
    final result = await scanProject(ScanOptions(root: dir.path));
    final after = dir.listSync(recursive: true).map((e) => e.path).toSet();

    expect(after, before);
    final json = result.json;
    final summary = json['summary']! as Map<String, Object?>;
    expect(summary['filesScanned'], 2);
    expect(summary['generatedFilesSkipped'], 1);
    final findings = json['findings']! as List;
    expect(
      findings.map((f) => (f as Map)['smell']),
      contains('mixed-state-management'),
    );
    expect((json['analyzer']! as Map)['status'], 'skipped');
  });
}
