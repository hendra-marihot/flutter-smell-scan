/// Data types shared by the scanner and the report writer.
library;

enum Severity { high, medium, low }

int severityWeight(Severity s) => switch (s) {
  Severity.high => 5,
  Severity.medium => 2,
  Severity.low => 1,
};

class Finding {
  Finding({
    required this.smell,
    required this.severity,
    required this.file,
    required this.line,
    required this.message,
    this.symbol,
    this.value,
    this.threshold,
  });

  /// Smell id from references/smell-catalog.md, e.g. `long-function`.
  final String smell;
  final Severity severity;

  /// Path relative to the scan root, or `(project)` for project-level smells.
  final String file;
  final int line;
  final String message;

  /// Class, method or field the finding is about, when there is one.
  final String? symbol;

  /// Measured value and the threshold it crossed, for metric smells.
  final num? value;
  final num? threshold;

  Map<String, Object?> toJson() => {
    'smell': smell,
    'severity': severity.name,
    'file': file,
    'line': line,
    if (symbol != null) 'symbol': symbol,
    if (value != null) 'value': value,
    if (threshold != null) 'threshold': threshold,
    'message': message,
  };
}

/// Metric thresholds. Override any of them with `--set key=value`.
class Thresholds {
  Thresholds([Map<String, int> overrides = const {}])
    : values = {...defaults, ...overrides};

  static const defaults = <String, int>{
    // Physical lines in one file. Same default as DCM's avoid-long-files.
    'long-file': 500,
    // Lines in one function or method, excluding build().
    'long-function': 50,
    // Lines in one build() method.
    'long-build-method': 100,
    // Approximate depth of nested constructor calls inside build().
    'deep-widget-nesting': 12,
    // Parameters in one function (constructors that only use this./super. are skipped).
    'long-parameter-list': 5,
    // Lines in one class that is not a state holder.
    'large-class': 300,
    // Cyclomatic complexity of one function.
    'high-complexity': 20,
    // Lines in one Bloc/Cubit/ChangeNotifier/Notifier/ViewModel class.
    'state-holder-lines': 250,
    // Public methods in one state holder class.
    'state-holder-methods': 12,
    // setState() calls in one State class.
    'setstate-heavy': 8,
  };

  final Map<String, int> values;

  int operator [](String key) => values[key]!;
}

/// Severity for a metric smell: high at twice the threshold, else medium.
Severity metricSeverity(num value, num threshold) =>
    value >= threshold * 2 ? Severity.high : Severity.medium;
