#!/usr/bin/env bash
# Build the release APK with symbol obfuscation and a separate debug-symbol
# directory.
#
# Keep `build/symbols/` for every published build: without it a crash report
# cannot be symbolicated. Do NOT commit it, and do not ship it inside the APK.
set -euo pipefail

cd "$(dirname "$0")/.."

# The Flutter tool occasionally cannot overwrite an existing assets bundle.
rm -rf build/app/intermediates/flutter

flutter build apk --release \
  --obfuscate \
  --split-debug-info=build/symbols

echo
echo "APK:    build/app/outputs/flutter-apk/app-release.apk"
echo "Symbols: build/symbols (archive this next to the APK; never commit)"
ls -lh build/app/outputs/flutter-apk/app-release.apk
