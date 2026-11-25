/// Read-only Flutter/Dart code-smell scanner.
library;

export 'src/file_scanner.dart' show FileScanner, FileReport;
export 'src/model.dart';
export 'src/project_scanner.dart' show ScanOptions, ScanResult, scanProject;
