/// Per-file smell detectors. Works on the unresolved AST (parse only), so it
/// needs no `pub get` in the target project and never writes to it.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'model.dart';

/// State-management families, detected by import URI prefix.
const stateFamilies = <String, List<String>>{
  'bloc': ['package:flutter_bloc/', 'package:bloc/', 'package:hydrated_bloc/'],
  'provider': ['package:provider/'],
  'riverpod': [
    'package:flutter_riverpod/',
    'package:riverpod/',
    'package:hooks_riverpod/',
    'package:riverpod_annotation/',
  ],
  'getx': ['package:get/'],
  'mobx': ['package:mobx/', 'package:flutter_mobx/'],
  'redux': ['package:redux/', 'package:flutter_redux/'],
  'signals': ['package:signals/', 'package:signals_flutter/'],
};

/// Packages that belong in the data layer, not in widget files.
const _dataLayerImports = [
  'package:dio/',
  'package:http/',
  'package:shared_preferences/',
  'package:sqflite/',
  'package:drift/',
  'package:hive/',
  'package:hive_flutter/',
  'package:isar/',
  'package:cloud_firestore/',
  'package:firebase_database/',
  'package:graphql/',
  'package:graphql_flutter/',
  'package:flutter_secure_storage/',
];

/// Superclasses (or mixins) that mark a class as a state holder.
const _stateHolderSupers = {
  'Cubit',
  'Bloc',
  'HydratedCubit',
  'HydratedBloc',
  'ChangeNotifier',
  'StateNotifier',
  'Notifier',
  'AsyncNotifier',
  'FamilyNotifier',
  'FamilyAsyncNotifier',
  'AutoDisposeNotifier',
  'AutoDisposeAsyncNotifier',
  'StreamNotifier',
  'GetxController',
  'GetxService',
};

/// Field types a State class must release in dispose().
const _disposableTypes = {
  'TextEditingController',
  'AnimationController',
  'ScrollController',
  'PageController',
  'TabController',
  'FocusNode',
  'FocusScopeNode',
  'StreamSubscription',
  'StreamController',
  'Timer',
  'ValueNotifier',
  'TransformationController',
  'DraggableScrollableController',
  'SearchController',
  'VideoPlayerController',
  'CameraController',
};

/// Disposables whose leak costs memory only; reported as medium, not high.
const _lowCostDisposables = {
  'ValueNotifier',
  'TextEditingController',
  'FocusNode',
  'FocusScopeNode',
  'ScrollController',
  'TransformationController',
  'SearchController',
};

final _todoPattern = RegExp(r'//+\s*(TODO|FIXME|HACK|XXX)\b', caseSensitive: false);

class TodoMarker {
  TodoMarker(this.line, this.text);
  final int line;
  final String text;
  Map<String, Object?> toJson() => {'line': line, 'text': text};
}

/// Result of scanning one file.
class FileReport {
  FileReport(this.path);

  final String path;
  int lines = 0;
  int classes = 0;
  int functions = 0;
  final findings = <Finding>[];
  final imports = <String>{};
  final stateFamilies = <String>{};
  final todos = <TodoMarker>[];
  int setStateClasses = 0;
  int changeNotifierClasses = 0;
  bool parseErrors = false;

  int get score =>
      findings.fold(0, (sum, f) => sum + severityWeight(f.severity));
}

class FileScanner {
  FileScanner({
    required this.path,
    required this.unit,
    required this.content,
    required this.t,
  }) : _lineInfo = unit.lineInfo;

  final String path;
  final CompilationUnit unit;
  final String content;
  final Thresholds t;
  final LineInfo _lineInfo;

  late final FileReport report = FileReport(path);

  int _line(int offset) => _lineInfo.getLocation(offset).lineNumber;
  int _span(AstNode n) => _line(n.end) - _line(n.offset) + 1;

  bool get _isPresentationPath => RegExp(
    r'(^|/)(presentation|ui|view|views|screens?|pages?|widgets?)/',
  ).hasMatch(path);

  FileReport scan() {
    report.lines = _lineInfo.lineCount;
    _scanImports();
    _scanTodos();

    if (report.lines > t['long-file']) {
      report.findings.add(
        Finding(
          smell: 'long-file',
          severity: metricSeverity(report.lines, t['long-file']),
          file: path,
          line: 1,
          value: report.lines,
          threshold: t['long-file'],
          message: 'File has ${report.lines} lines.',
        ),
      );
    }

    var declaresUi = false;
    for (final decl in unit.declarations) {
      if (decl is ClassDeclaration) {
        report.classes++;
        final ui = _scanClass(
          node: decl,
          name: decl.namePart.typeName.lexeme,
          superName: decl.extendsClause?.superclass.name.lexeme,
          mixins: [
            for (final m in decl.withClause?.mixinTypes ?? const <NamedType>[])
              m.name.lexeme,
          ],
          members: decl.body.members,
        );
        declaresUi = declaresUi || ui;
      } else if (decl is MixinDeclaration) {
        report.classes++;
        _scanClass(
          node: decl,
          name: decl.name.lexeme,
          superName: null,
          mixins: const [],
          members: decl.body.members,
        );
      } else if (decl is ExtensionDeclaration) {
        _scanClass(
          node: decl,
          name: decl.name?.lexeme ?? '<extension>',
          superName: null,
          mixins: const [],
          members: decl.body.members,
        );
      } else if (decl is ExtensionTypeDeclaration) {
        _scanClass(
          node: decl,
          name: decl.namePart.typeName.lexeme,
          superName: null,
          mixins: const [],
          members: decl.body.members,
        );
      } else if (decl is EnumDeclaration) {
        _scanClass(
          node: decl,
          name: decl.namePart.typeName.lexeme,
          superName: null,
          mixins: const [],
          members: decl.body.members,
        );
      } else if (decl is FunctionDeclaration) {
        report.functions++;
        _scanFunction(
          node: decl,
          name: decl.name.lexeme,
          params: decl.functionExpression.parameters?.parameters,
          body: decl.functionExpression.body,
          isBuild: false,
        );
      }
    }

    if (declaresUi) _scanUiImports();
    unit.accept(_CatchVisitor(this));
    return report;
  }

  void _scanImports() {
    for (final d in unit.directives) {
      if (d is! ImportDirective) continue;
      final uri = d.uri.stringValue;
      if (uri == null) continue;
      report.imports.add(uri);
      stateFamilies.forEach((family, prefixes) {
        if (prefixes.any(uri.startsWith)) report.stateFamilies.add(family);
      });
    }
  }

  void _scanTodos() {
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final m = _todoPattern.firstMatch(lines[i]);
      if (m != null) {
        final text = lines[i].substring(m.start).trim();
        report.todos.add(
          TodoMarker(i + 1, text.length > 120 ? text.substring(0, 120) : text),
        );
      }
    }
  }

  /// Flags data-layer imports in files that declare a widget or State class.
  void _scanUiImports() {
    for (final d in unit.directives) {
      if (d is! ImportDirective) continue;
      final uri = d.uri.stringValue ?? '';
      final pkg = _dataLayerImports.where(uri.startsWith).firstOrNull;
      if (pkg != null) {
        report.findings.add(
          Finding(
            smell: 'ui-layer-leak',
            severity: Severity.medium,
            file: path,
            line: _line(d.offset),
            symbol: uri,
            message:
                'A file that declares a widget imports the data-layer package '
                '`${pkg.substring(8, pkg.length - 1)}`.',
          ),
        );
      } else if (_isPresentationPath &&
          !uri.startsWith('dart:') &&
          RegExp(r'(^|/)data/').hasMatch(uri)) {
        report.findings.add(
          Finding(
            smell: 'ui-layer-leak',
            severity: Severity.low,
            file: path,
            line: _line(d.offset),
            symbol: uri,
            message:
                'A presentation file imports the data layer directly '
                '(`$uri`). Depend on the domain layer instead.',
          ),
        );
      }
    }
  }

  /// Returns true when the class is a widget or State class.
  bool _scanClass({
    required AstNode node,
    required String name,
    required String? superName,
    required List<String> mixins,
    required List<ClassMember> members,
  }) {
    final methods = members.whereType<MethodDeclaration>().toList();
    final isUi = methods.any(_isBuildMethod);
    final isState = superName == 'State' || superName == 'ConsumerState';
    final isStateHolder =
        !isUi &&
        (_stateHolderSupers.contains(superName) ||
            (superName?.startsWith(r'_$') ?? false) ||
            mixins.contains('ChangeNotifier') ||
            name.endsWith('ViewModel'));
    final classLines = _span(node);
    final classLine = _line(node.offset);

    if (superName == 'ChangeNotifier' || mixins.contains('ChangeNotifier')) {
      report.changeNotifierClasses++;
    }

    // Size of the class.
    if (isStateHolder) {
      final publicMethods = methods
          .where((m) => !m.name.lexeme.startsWith('_') && !m.isStatic)
          .length;
      final tooLong = classLines > t['state-holder-lines'];
      final tooWide = publicMethods > t['state-holder-methods'];
      if (tooLong || tooWide) {
        final sev = [
          if (tooLong) metricSeverity(classLines, t['state-holder-lines']),
          if (tooWide) metricSeverity(publicMethods, t['state-holder-methods']),
        ].reduce((a, b) => a.index < b.index ? a : b);
        report.findings.add(
          Finding(
            smell: 'oversized-state-holder',
            severity: sev,
            file: path,
            line: classLine,
            symbol: name,
            value: tooLong ? classLines : publicMethods,
            threshold: tooLong
                ? t['state-holder-lines']
                : t['state-holder-methods'],
            message:
                '`$name` (${superName ?? 'state holder'}) has $classLines lines '
                'and $publicMethods public methods.',
          ),
        );
      }
    } else if (classLines > t['large-class']) {
      report.findings.add(
        Finding(
          smell: 'large-class',
          severity: metricSeverity(classLines, t['large-class']),
          file: path,
          line: classLine,
          symbol: name,
          value: classLines,
          threshold: t['large-class'],
          message: 'Class `$name` has $classLines lines.',
        ),
      );
    }

    // Functions inside the class.
    for (final m in members) {
      if (m is MethodDeclaration) {
        report.functions++;
        final isBuild = _isBuildMethod(m);
        _scanFunction(
          node: m,
          name: '$name.${m.name.lexeme}',
          params: m.parameters?.parameters,
          body: m.body,
          isBuild: isBuild,
        );
        if (isUi && !isBuild && !m.isStatic && _returnsWidget(m.returnType)) {
          final lines = _span(m);
          report.findings.add(
            Finding(
              smell: 'widget-helper-method',
              severity: lines > 20 ? Severity.medium : Severity.low,
              file: path,
              line: _line(m.offset),
              symbol: '$name.${m.name.lexeme}',
              value: lines,
              message:
                  '`${m.name.lexeme}` returns a widget from a method '
                  '($lines lines). Extract a widget class so Flutter can '
                  'rebuild and const-cache it on its own.',
            ),
          );
        }
      } else if (m is ConstructorDeclaration) {
        report.functions++;
        // Named constructor parameters are the Dart idiom for data classes
        // (freezed, json_serializable, widgets), so only positional ones
        // count. Redirecting factories (freezed) are skipped entirely.
        final positional = m.parameters.parameters
            .where((p) => p.isPositional)
            .toList();
        final onlyFieldParams = positional.every(
          (p) => p is FieldFormalParameter || p is SuperFormalParameter,
        );
        _scanFunction(
          node: m,
          name: '$name${m.name == null ? '' : '.${m.name!.lexeme}'}',
          params: onlyFieldParams || m.redirectedConstructor != null
              ? null
              : positional,
          body: m.body,
          isBuild: false,
        );
      }
    }

    if (isUi) _scanUiClassBody(node, name);
    if (isState) _scanStateClass(node, name, members, methods);
    return isUi;
  }

  bool _isBuildMethod(MethodDeclaration m) {
    if (m.name.lexeme != 'build') return false;
    final params = m.parameters?.parameters;
    if (params == null || params.isEmpty) return false;
    return params.first.type?.toSource().startsWith('BuildContext') ?? false;
  }

  bool _returnsWidget(TypeAnnotation? type) {
    if (type == null) return false;
    return RegExp(r'^(\w+)?Widget\??$').hasMatch(type.toSource());
  }

  void _scanFunction({
    required AstNode node,
    required String name,
    required List<FormalParameter>? params,
    required FunctionBody body,
    required bool isBuild,
  }) {
    final lines = _span(node);
    final line = _line(node.offset);

    if (isBuild) {
      if (lines > t['long-build-method']) {
        report.findings.add(
          Finding(
            smell: 'long-build-method',
            severity: metricSeverity(lines, t['long-build-method']),
            file: path,
            line: line,
            symbol: name,
            value: lines,
            threshold: t['long-build-method'],
            message: '`$name` is $lines lines long.',
          ),
        );
      }
      final depth = _WidgetDepthVisitor();
      body.accept(depth);
      if (depth.maxDepth > t['deep-widget-nesting']) {
        report.findings.add(
          Finding(
            smell: 'deep-widget-nesting',
            severity: metricSeverity(depth.maxDepth, t['deep-widget-nesting']),
            file: path,
            line: _line(depth.deepestOffset ?? node.offset),
            symbol: name,
            value: depth.maxDepth,
            threshold: t['deep-widget-nesting'],
            message:
                '`$name` nests constructor calls ${depth.maxDepth} levels deep '
                '(approximate: counts every capitalised call). The line points '
                'at the deepest call.',
          ),
        );
      }
    } else if (lines > t['long-function']) {
      report.findings.add(
        Finding(
          smell: 'long-function',
          severity: metricSeverity(lines, t['long-function']),
          file: path,
          line: line,
          symbol: name,
          value: lines,
          threshold: t['long-function'],
          message: '`$name` is $lines lines long.',
        ),
      );
    }

    final complexity = _ComplexityVisitor();
    body.accept(complexity);
    if (complexity.value > t['high-complexity']) {
      report.findings.add(
        Finding(
          smell: 'high-complexity',
          severity: metricSeverity(complexity.value, t['high-complexity']),
          file: path,
          line: line,
          symbol: name,
          value: complexity.value,
          threshold: t['high-complexity'],
          message: '`$name` has cyclomatic complexity ${complexity.value}.',
        ),
      );
    }

    if (params != null && params.length > t['long-parameter-list']) {
      report.findings.add(
        Finding(
          smell: 'long-parameter-list',
          severity: metricSeverity(params.length, t['long-parameter-list']),
          file: path,
          line: line,
          symbol: name,
          value: params.length,
          threshold: t['long-parameter-list'],
          message: '`$name` takes ${params.length} parameters.',
        ),
      );
    }
  }

  /// Data-layer calls (HTTP, storage, JSON) made directly inside a widget.
  void _scanUiClassBody(AstNode node, String name) {
    final v = _DataCallVisitor();
    node.accept(v);
    if (v.hits.isEmpty) return;
    final first = v.hits.first;
    report.findings.add(
      Finding(
        smell: 'ui-layer-leak',
        severity: Severity.medium,
        file: path,
        line: _line(first.offset),
        symbol: name,
        value: v.hits.length,
        message:
            'Widget `$name` makes ${v.hits.length} data-layer call(s) itself, '
            'first `${first.label}`. Move them to a repository or state holder.',
      ),
    );
  }

  void _scanStateClass(
    AstNode node,
    String name,
    List<ClassMember> members,
    List<MethodDeclaration> methods,
  ) {
    final calls = _CallCounter({'setState', 'addListener', 'removeListener'});
    node.accept(calls);

    final setStates = calls.counts['setState'] ?? 0;
    if (setStates > 0) report.setStateClasses++;
    if (setStates > t['setstate-heavy']) {
      report.findings.add(
        Finding(
          smell: 'setstate-heavy',
          severity: metricSeverity(setStates, t['setstate-heavy']),
          file: path,
          line: _line(node.offset),
          symbol: name,
          value: setStates,
          threshold: t['setstate-heavy'],
          message:
              '`$name` calls setState() $setStates times. The widget likely '
              'holds business state that belongs in a state holder.',
        ),
      );
    }

    final dispose = methods.where((m) => m.name.lexeme == 'dispose').firstOrNull;
    final released = _ReleaseVisitor();
    dispose?.body.accept(released);
    final disposeIdentifiers = _IdentifierCollector();
    dispose?.body.accept(disposeIdentifiers);

    final ownedFields = <String>{};
    for (final member in members.whereType<FieldDeclaration>()) {
      if (member.isStatic) continue;
      final declaredType = _baseTypeName(member.fields.type?.toSource());
      for (final v in member.fields.variables) {
        final type = declaredType ?? _initializerTypeName(v.initializer);
        if (type == null || !_disposableTypes.contains(type)) continue;
        final field = v.name.lexeme;
        ownedFields.add(field);
        if (released.receivers.contains(field)) continue;
        // Mentioned in dispose() but not as a receiver, e.g.
        // `[_a, _b].forEach((c) => c.dispose())`: report, but lower.
        final mentioned = disposeIdentifiers.names.contains(field);
        // Timers, subscriptions and animation controllers keep running after
        // the screen is gone. An undisposed notifier only holds memory.
        final severity = mentioned
            ? Severity.low
            : _lowCostDisposables.contains(type)
            ? Severity.medium
            : Severity.high;
        report.findings.add(
          Finding(
            smell: 'missing-dispose',
            severity: severity,
            file: path,
            line: _line(v.offset),
            symbol: '$name.$field',
            message: dispose == null
                ? '`$name` owns `$field` ($type) but has no dispose() method.'
                : mentioned
                ? '`$name.dispose()` mentions `$field` ($type) but does not '
                      'call dispose/cancel/close on it directly. Confirm it is '
                      'released.'
                : '`$name.dispose()` never releases `$field` ($type). Check '
                      'helper methods called from dispose() before fixing.',
          ),
        );
      }
    }

    final adds = calls.counts['addListener'] ?? 0;
    final removes = calls.counts['removeListener'] ?? 0;
    final addTargets = calls.receivers['addListener'] ?? const <String>{};
    final allOwned =
        addTargets.isNotEmpty && addTargets.every(ownedFields.contains);
    if (adds > 0 && removes == 0 && !allOwned) {
      report.findings.add(
        Finding(
          smell: 'listener-not-removed',
          severity: Severity.low,
          file: path,
          line: _line(calls.firstOffset['addListener']!),
          symbol: name,
          value: adds,
          message:
              '`$name` calls addListener() $adds time(s) and never '
              'removeListener(). This leaks only when the listenable outlives '
              'the widget; skip it when this class creates and disposes the '
              'listenable.',
        ),
      );
    }
  }

  String? _baseTypeName(String? source) {
    if (source == null) return null;
    final m = RegExp(r'^(\w+)').firstMatch(source);
    return m?.group(1);
  }

  String? _initializerTypeName(Expression? init) {
    if (init is InstanceCreationExpression) {
      return init.constructorName.type.name.lexeme;
    }
    if (init is MethodInvocation) {
      final target = init.target;
      if (target == null) return init.methodName.name;
      if (target is SimpleIdentifier) return target.name;
    }
    return null;
  }

  void _addCatchFinding(CatchClause node) {
    final statements = node.body.statements;
    if (statements.isEmpty) {
      // `catch (_) { // Analytics must never break the upload. }` documents a
      // deliberate ignore. Only uncommented empty catches are smells.
      if (node.body.rightBracket.precedingComments != null) return;
      report.findings.add(
        Finding(
          smell: 'swallowed-exception',
          severity: Severity.medium,
          file: path,
          line: _line(node.offset),
          message: 'Empty catch block hides the error.',
        ),
      );
      return;
    }
    final onlyLogs = statements.every((s) {
      if (s is! ExpressionStatement) return false;
      final e = s.expression;
      return e is MethodInvocation &&
          const {'print', 'debugPrint', 'log'}.contains(e.methodName.name);
    });
    if (onlyLogs) {
      report.findings.add(
        Finding(
          smell: 'swallowed-exception',
          severity: Severity.low,
          file: path,
          line: _line(node.offset),
          message:
              'Catch block only prints the error. The caller and the user '
              'never learn that the operation failed.',
        ),
      );
    }
  }
}

class _CatchVisitor extends RecursiveAstVisitor<void> {
  _CatchVisitor(this.scanner);
  final FileScanner scanner;

  @override
  void visitCatchClause(CatchClause node) {
    scanner._addCatchFinding(node);
    super.visitCatchClause(node);
  }
}

bool _isUpper(String s) =>
    s.isNotEmpty && s[0].toUpperCase() == s[0] && s[0].toLowerCase() != s[0];

/// Approximate widget-tree depth: nesting of capitalised constructor calls.
class _WidgetDepthVisitor extends RecursiveAstVisitor<void> {
  int _depth = 0;
  int maxDepth = 0;
  int? deepestOffset;

  void _enter(AstNode node, void Function() visitChildren) {
    _depth++;
    if (_depth > maxDepth) {
      maxDepth = _depth;
      deepestOffset = node.offset;
    }
    visitChildren();
    _depth--;
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) =>
      _enter(node, () => super.visitInstanceCreationExpression(node));

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    final name = node.methodName.name;
    final looksLikeConstructor =
        (target == null && _isUpper(name)) ||
        (target is SimpleIdentifier &&
            _isUpper(target.name) &&
            !const {'of', 'maybeOf'}.contains(name));
    if (looksLikeConstructor) {
      _enter(node, () => super.visitMethodInvocation(node));
    } else {
      super.visitMethodInvocation(node);
    }
  }
}

class _ComplexityVisitor extends RecursiveAstVisitor<void> {
  int value = 1;

  @override
  void visitIfStatement(IfStatement node) {
    value++;
    super.visitIfStatement(node);
  }

  @override
  void visitIfElement(IfElement node) {
    value++;
    super.visitIfElement(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    value++;
    super.visitForStatement(node);
  }

  @override
  void visitForElement(ForElement node) {
    value++;
    super.visitForElement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    value++;
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    value++;
    super.visitDoStatement(node);
  }

  @override
  void visitCatchClause(CatchClause node) {
    value++;
    super.visitCatchClause(node);
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    value++;
    super.visitConditionalExpression(node);
  }

  @override
  void visitSwitchCase(SwitchCase node) {
    value++;
    super.visitSwitchCase(node);
  }

  @override
  void visitSwitchPatternCase(SwitchPatternCase node) {
    value++;
    super.visitSwitchPatternCase(node);
  }

  @override
  void visitSwitchExpressionCase(SwitchExpressionCase node) {
    value++;
    super.visitSwitchExpressionCase(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final op = node.operator.lexeme;
    if (op == '&&' || op == '||' || op == '??') value++;
    super.visitBinaryExpression(node);
  }
}

class _DataCall {
  _DataCall(this.offset, this.label);
  final int offset;
  final String label;
}

/// Finds HTTP, storage and JSON calls written directly in widget code.
class _DataCallVisitor extends RecursiveAstVisitor<void> {
  final hits = <_DataCall>[];

  static const _functions = {'jsonDecode', 'jsonEncode', 'openDatabase'};
  static const _constructors = {'Dio', 'HttpClient'};
  static final _targets = RegExp(
    r'^(http|dio|_dio|Dio|SharedPreferences|FirebaseFirestore\.instance|'
    r'FirebaseDatabase\.instance|Hive|_client|client|httpClient)$',
  );
  static const _httpVerbs = {
    'get', 'post', 'put', 'patch', 'delete', 'head', 'fetch', 'request',
    'getInstance', 'openBox', 'collection', 'doc', 'ref',
  };

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    final target = node.target?.toSource();
    if (target == null &&
        (_functions.contains(name) || _constructors.contains(name))) {
      hits.add(_DataCall(node.offset, '$name(...)'));
    } else if (target != null &&
        _targets.hasMatch(target) &&
        _httpVerbs.contains(name)) {
      hits.add(_DataCall(node.offset, '$target.$name(...)'));
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type.name.lexeme;
    if (_constructors.contains(type)) {
      hits.add(_DataCall(node.offset, '$type(...)'));
    }
    super.visitInstanceCreationExpression(node);
  }
}

/// The receiver name of a call, with `this.` and `!` removed, and with the
/// cascade target used for cascades: `_c.x()`, `this._c.x()`, `_c!.x()`,
/// `_c?.x()` and `_c..x()` all give `_c`.
String? _receiverName(MethodInvocation node) {
  var target = node.realTarget;
  while (target is PostfixExpression || target is ParenthesizedExpression) {
    target = target is PostfixExpression
        ? target.operand
        : (target as ParenthesizedExpression).expression;
  }
  if (target is SimpleIdentifier) return target.name;
  if (target is PropertyAccess && target.target is ThisExpression) {
    return target.propertyName.name;
  }
  return target?.toSource();
}

class _CallCounter extends RecursiveAstVisitor<void> {
  _CallCounter(this.names);
  final Set<String> names;
  final counts = <String, int>{};
  final firstOffset = <String, int>{};
  final receivers = <String, Set<String>>{};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if (names.contains(name)) {
      counts[name] = (counts[name] ?? 0) + 1;
      firstOffset[name] ??= node.offset;
      final r = _receiverName(node);
      if (r != null) receivers.putIfAbsent(name, () => {}).add(r);
    }
    super.visitMethodInvocation(node);
  }
}

/// Receivers of dispose()/cancel()/close() calls, including cascades
/// such as `_c..removeListener(f)..dispose()`.
class _ReleaseVisitor extends RecursiveAstVisitor<void> {
  final receivers = <String>{};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (const {'dispose', 'cancel', 'close'}.contains(node.methodName.name)) {
      final r = _receiverName(node);
      if (r != null) receivers.add(r);
    }
    super.visitMethodInvocation(node);
  }
}

class _IdentifierCollector extends RecursiveAstVisitor<void> {
  final names = <String>{};

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    names.add(node.name);
    super.visitSimpleIdentifier(node);
  }
}
