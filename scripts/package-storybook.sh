#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

swift build -c release --product MethamphetamineStorybook
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/Methamphetamine Storybook.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
install -m 755 "$BIN_DIR/MethamphetamineStorybook" "$APP_DIR/Contents/MacOS/MethamphetamineStorybook"
install -m 644 "$PROJECT_DIR/Resources/StorybookInfo.plist" "$APP_DIR/Contents/Info.plist"
install -m 644 "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
install -m 644 "$PROJECT_DIR/Resources/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"

plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

test -x "$APP_DIR/Contents/MacOS/MethamphetamineStorybook"
test "$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")" = "app.methamphetamine.Methamphetamine.Storybook"
test "$('/usr/libexec/PlistBuddy' -c 'Print :LSUIElement' "$APP_DIR/Contents/Info.plist")" = "false"

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_DIR/Contents/Info.plist")" = "AppIcon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP_DIR/Contents/Info.plist")" = "AppIcon"
test -f "$APP_DIR/Contents/Resources/AppIcon.icns"
test -f "$APP_DIR/Contents/Resources/Assets.car"

echo "$APP_DIR"
