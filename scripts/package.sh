#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

BUILD_ARGS=(-c release --disable-sandbox --arch arm64 --arch x86_64)
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
STAGING_DIR="$(mktemp -d "/private/tmp/codexnotsleep-package.XXXXXX")"
DMG_ROOT="$STAGING_DIR/dmg"
STAGING_APP="$DMG_ROOT/Codex Not Sleep.app"

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

test -x "$STAGING_APP/Contents/MacOS/CodexNotSleep"
lipo "$STAGING_APP/Contents/MacOS/CodexNotSleep" -verify_arch arm64 x86_64
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$STAGING_APP/Contents/Info.plist")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$STAGING_APP/Contents/Info.plist")" = "AppIcon.icns"
test -f "$STAGING_APP/Contents/Resources/AppIcon.icns"
test ! -e "$STAGING_APP/Contents/Helpers"
test ! -e "$STAGING_APP/Contents/Resources/meth-privileged-helper-scaffold"

if grep -a -q 'tell application "Amphetamine"' "$STAGING_APP/Contents/MacOS/CodexNotSleep"; then
  echo "Unexpected legacy Amphetamine code in packaged binary" >&2
  exit 1
fi

if /usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription' "$STAGING_APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "Unexpected Apple Events permission description in packaged Info.plist" >&2
  exit 1
fi

ln -s /Applications "$DMG_ROOT/Applications"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGING_APP/Contents/Info.plist")"
DMG_NAME="Codex-Not-Sleep-$VERSION.dmg"
STAGING_DMG="$STAGING_DIR/$DMG_NAME"
OUTPUT_DMG="$PROJECT_DIR/dist/$DMG_NAME"

mkdir -p "$PROJECT_DIR/dist"
hdiutil create \
  -volname "Codex Not Sleep" \
  -srcfolder "$DMG_ROOT" \
  -format UDZO \
  -ov \
  "$STAGING_DMG"
hdiutil verify "$STAGING_DMG"
mv -f "$STAGING_DMG" "$OUTPUT_DMG"

echo "$OUTPUT_DMG"
