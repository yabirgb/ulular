#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/ulular.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ulular" "$APP/Contents/MacOS/ulular"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Use the same pixel design for the template menu-bar image and Finder icon.
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
swiftc Sources/Ulular/UlularLogo.swift scripts/generate-icons.swift -o "$ICON_WORK/generate-icons"
"$ICON_WORK/generate-icons" "$ICON_WORK/ulular.iconset"
iconutil -c icns "$ICON_WORK/ulular.iconset" -o "$APP/Contents/Resources/ulular.icns"
# Set CODESIGN_IDENTITY to a stable certificate so macOS keeps granted permissions
# across rebuilds. Ad-hoc signing (the default) changes identity on every build.
# Distribution requires Developer ID signing/notarization.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
printf '\nBuilt %s\nLaunch with: open "%s"\n' "$APP" "$APP"
