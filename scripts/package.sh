#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/Codex Not Sleep.app"
STAGING_DIR="$(mktemp -d "/private/tmp/codexnotsleep-package.XXXXXX")"
STAGING_APP="$STAGING_DIR/Codex Not Sleep.app"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
install -m 755 "$BIN_DIR/CodexNotSleep" "$STAGING_APP/Contents/MacOS/CodexNotSleep"
install -m 644 "$PROJECT_DIR/Resources/Info.plist" "$STAGING_APP/Contents/Info.plist"
install -m 644 "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGING_APP/Contents/Resources/AppIcon.icns"

plutil -lint "$STAGING_APP/Contents/Info.plist"
xattr -cr "$STAGING_APP"
codesign --force --sign - "$STAGING_APP"
codesign --verify --deep --strict "$STAGING_APP"

rm -rf "$APP_DIR"
mv "$STAGING_APP" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

test -x "$APP_DIR/Contents/MacOS/CodexNotSleep"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP_DIR/Contents/Info.plist")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_DIR/Contents/Info.plist")" = "AppIcon.icns"
test -f "$APP_DIR/Contents/Resources/AppIcon.icns"
test ! -e "$APP_DIR/Contents/Helpers"
test ! -e "$APP_DIR/Contents/Resources/meth-privileged-helper-scaffold"

if grep -a -q 'tell application "Amphetamine"' "$APP_DIR/Contents/MacOS/CodexNotSleep"; then
  echo "Unexpected legacy Amphetamine code in packaged binary" >&2
  exit 1
fi

if /usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription' "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1; then
  echo "Unexpected Apple Events permission description in packaged Info.plist" >&2
  exit 1
fi

echo "$APP_DIR"
