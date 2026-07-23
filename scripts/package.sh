#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/Methamphetamine.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
install -m 755 "$BIN_DIR/Methamphetamine" "$APP_DIR/Contents/MacOS/Methamphetamine"
install -m 644 "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
install -m 644 "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

test -x "$APP_DIR/Contents/MacOS/Methamphetamine"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP_DIR/Contents/Info.plist")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_DIR/Contents/Info.plist")" = "AppIcon.icns"
test -f "$APP_DIR/Contents/Resources/AppIcon.icns"
test ! -e "$APP_DIR/Contents/Helpers"
test ! -e "$APP_DIR/Contents/Resources/meth-privileged-helper-scaffold"

if grep -a -q 'tell application "Amphetamine"' "$APP_DIR/Contents/MacOS/Methamphetamine"; then
  echo "Unexpected legacy Amphetamine code in packaged binary" >&2
  exit 1
fi

if /usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription' "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1; then
  echo "Unexpected Apple Events permission description in packaged Info.plist" >&2
  exit 1
fi

echo "$APP_DIR"
