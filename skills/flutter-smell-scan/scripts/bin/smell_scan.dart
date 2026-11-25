import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:smell_scan/smell_scan.dart';

const _usage = '''
Usage: dart run bin/smell_scan.dart <project-dir> [options]

Scans a Flutter/Dart project for code smells and writes a JSON report.
The scan is read-only: it never runs pub get and never writes inside
<project-dir>.
''';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption(
      'out',
      abbr: 'o',
      help: 'Where to write the JSON report. Must be outside the project.',
    )
    ..addFlag('include-tests', help: 'Also scan test/ and integration_test/.')
    ..addFlag(
      'analyze',
      defaultsTo: true,
      help: 'Run `dart analyze` and include its diagnostics.',
    )
    ..addOption('top', defaultsTo: '15', help: 'Number of hotspot files.')
    ..addFlag(
      'readiness',
      help:
          'Add the agent-readiness scorecard (instruction files, commands, '
          'scripts, tests, unused files, git co-change, CI, lint config, '
          'formatting) to the report.',
    )
    ..addFlag(
      'format',
      defaultsTo: true,
      help:
          'With --readiness, run `dart format --output=none` to count '
          'unformatted files. Writes nothing.',
    )
    ..addMultiOption(
      'set',
      help:
          'Override a threshold, e.g. --set long-function=40. '
          'Keys: ${Thresholds.defaults.keys.join(', ')}',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n$_usage${parser.usage}');
    exit(64);
  }
  if (args['help'] as bool || args.rest.length != 1) {
    stdout.writeln('$_usage${parser.usage}');
    exit(args['help'] as bool ? 0 : 64);
  }

  final root = p.normalize(p.absolute(args.rest.single));
  if (!Directory(root).existsSync()) {
    stderr.writeln('Not a directory: $root');
    exit(66);
  }

  final overrides = <String, int>{};
  for (final s in args['set'] as List<String>) {
    final parts = s.split('=');
    final value = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (value == null || !Thresholds.defaults.containsKey(parts[0])) {
      stderr.writeln('Bad --set "$s". Use key=int with a known key.');
      exit(64);
    }
    overrides[parts[0]] = value;
  }

  final out = p.normalize(
    p.absolute(
      args['out'] as String? ??
          p.join(
            Directory.systemTemp.path,
            'flutter-smell-scan',
            '${p.basename(root)}-report.json',
          ),
    ),
  );
  if (p.isWithin(root, out)) {
    stderr.writeln(
      'Refusing to write the report inside the scanned project: $out',
    );
    exit(64);
  }

  final result = await scanProject(
    ScanOptions(
      root: root,
      includeTests: args['include-tests'] as bool,
      runAnalyzer: args['analyze'] as bool,
      top: int.tryParse(args['top'] as String) ?? 15,
      readiness: args['readiness'] as bool,
      formatCheck: args['format'] as bool,
      thresholds: Thresholds(overrides),
    ),
  );

  File(out)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result.json));

  final summary = result.json['summary']! as Map<String, Object?>;
  final sev = summary['bySeverity']! as Map<String, Object?>;
  final analyzer = result.json['analyzer']! as Map<String, Object?>;
  stdout.writeln('report: $out');
  stdout.writeln(
    'files: ${summary['filesScanned']}  lines: ${summary['totalLines']}  '
    'findings: ${summary['findings']} '
    '(high ${sev['high']}, medium ${sev['medium']}, low ${sev['low']})',
  );
  stdout.writeln(
    'analyzer: ${analyzer['status']}'
    '${analyzer['total'] != null ? ' (${analyzer['total']} diagnostics)' : ''}',
  );
  final readiness = result.json['readiness'] as Map<String, Object?>?;
  if (readiness != null) {
    final r = readiness['summary']! as Map<String, Object?>;
    stdout.writeln(
      'readiness: pass ${r['pass']}, warn ${r['warn']}, fail ${r['fail']}, '
      'unknown ${r['unknown']}',
    );
  }
}
