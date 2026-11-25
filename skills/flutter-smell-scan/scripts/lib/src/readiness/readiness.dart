/// Runs the agent-readiness scorecard.
library;

import '../file_scanner.dart';
import 'ax_checks.dart';
import 'dx_checks.dart';
import 'graph_checks.dart';
import 'history.dart';
import 'import_graph.dart';
import 'instructions.dart';
import 'model.dart';
import 'repo.dart';

Future<Map<String, Object?>> runReadiness({
  required String root,
  required List<FileReport> reports,
  required bool runFormat,
}) async {
  final repo = await Repo.open(root);
  final c = ReadinessContext(
    repo: repo,
    packages: findLocalPackages(repo),
    reports: reports,
    docs: loadInstructionDocs(repo),
  );
  final graph = ImportGraph.build(
    root: root,
    packages: c.packages,
    reports: reports,
  );
  final history = await History.read(repo);

  final checks = <ReadinessCheck>[
    await instructionFileCheck(c),
    taskCommandsCheck(c),
    nonInteractiveScriptsCheck(c),
    dangerousOpsCheck(c),
    fastLocalChecksCheck(c),
    honestExitCodesCheck(c),
    inconsistentPatternsCheck(c),
    generatedNoiseCheck(c),
    testMappingCheck(c, graph, history),
    unusedFilesCheck(c, graph),
    coChangeCheck(c, graph, history),
    lintConfigCheck(c),
    runFormat
        ? await formatCheck(c)
        : ReadinessCheck(
            id: 'format',
            area: 'dx',
            status: CheckStatus.unknown,
            summary: 'Skipped (--no-format).',
          ),
    ciParityCheck(c),
    setupDocsCheck(c),
  ];

  return {
    'summary': {
      for (final s in CheckStatus.values)
        s.name: checks.where((x) => x.status == s).length,
    },
    'git': repo.isGit,
    'vendoredPackages': [
      for (final p in c.packages)
        if (p.vendored) p.dir,
    ],
    'checks': [for (final x in checks) x.toJson()],
  };
}
