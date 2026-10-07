#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/MusicTask.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/MusicTask" "$APP/Contents/MacOS/MusicTask"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Set CODESIGN_IDENTITY to a stable certificate so macOS keeps granted permissions
# across rebuilds. Ad-hoc signing (the default) changes identity on every build.
# Distribution requires Developer ID signing/notarization.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
printf '\nBuilt %s\nLaunch with: open "%s"\n' "$APP" "$APP"
