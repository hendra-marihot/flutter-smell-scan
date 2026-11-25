#!/usr/bin/env bash
# Run the flutter-smell-scan scanner on a project.
#
# Usage: scan.sh <project-dir> --out <report.json> [options]
# Options are passed to bin/smell_scan.dart (run with --help to list them).
#
# The first run resolves the scanner's own dependencies inside this
# directory. It never runs `pub get` in, or writes to, the scanned project.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$DIR/.dart_tool/package_config.json"

if ! command -v dart >/dev/null 2>&1; then
  echo "dart is not on PATH. Install the Dart or Flutter SDK first." >&2
  exit 69
fi

if [ ! -f "$CONFIG" ] || [ "$DIR/pubspec.yaml" -nt "$CONFIG" ]; then
  echo "Resolving scanner dependencies (one time)..." >&2
  dart pub get --directory="$DIR" >/dev/null
  # pub get leaves the config untouched when nothing changed; mark it fresh.
  touch "$CONFIG"
fi

exec dart run "$DIR/bin/smell_scan.dart" "$@"
