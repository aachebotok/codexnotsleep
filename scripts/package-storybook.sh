#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

swift build -c release --product CodexNotSleepStorybook --disable-sandbox
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/Codex Not Sleep Storybook.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
install -m 755 "$BIN_DIR/CodexNotSleepStorybook" "$APP_DIR/Contents/MacOS/CodexNotSleepStorybook"
install -m 644 "$PROJECT_DIR/Resources/StorybookInfo.plist" "$APP_DIR/Contents/Info.plist"
install -m 644 "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

plutil -lint "$APP_DIR/Contents/Info.plist"
xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

test -x "$APP_DIR/Contents/MacOS/CodexNotSleepStorybook"
test "$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")" = "app.codexnotsleep.CodexNotSleep.Storybook"
test "$('/usr/libexec/PlistBuddy' -c 'Print :LSUIElement' "$APP_DIR/Contents/Info.plist")" = "false"

echo "$APP_DIR"
