#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
APP_SOURCE="$PROJECT_ROOT/outputs/Kayla Monitor.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/Resources/Info.plist")"
ARCHITECTURE="$(uname -m)"
DMG_NAME="Codex-Focus-Monitor-$VERSION-macOS-$ARCHITECTURE.dmg"
DMG_OUTPUT="$PROJECT_ROOT/outputs/$DMG_NAME"

if [[ -e "$DMG_OUTPUT" || -e "$DMG_OUTPUT.sha256" ]]; then
    echo "目标安装包已存在，请先备份或使用新版本号：$DMG_OUTPUT" >&2
    exit 1
fi

"$SCRIPT_DIRECTORY/build-app.sh"
test "$(/usr/bin/lipo -archs "$APP_SOURCE/Contents/MacOS/KaylaMonitor")" = "$ARCHITECTURE"
test "$(/usr/bin/lipo -archs "$APP_SOURCE/Contents/Helpers/kayla-monitor-hook")" = "$ARCHITECTURE"

STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/codex-focus-monitor-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
CONTENTS_DIRECTORY="$STAGING_DIRECTORY/contents"
mkdir "$CONTENTS_DIRECTORY"
/usr/bin/ditto --norsrc --noextattr --noacl "$APP_SOURCE" "$CONTENTS_DIRECTORY/Kayla Monitor.app"
ln -s /Applications "$CONTENTS_DIRECTORY/Applications"
cp "$PROJECT_ROOT/Resources/DMG-ReadMe.txt" "$CONTENTS_DIRECTORY/安装说明.txt"
/usr/bin/codesign --verify --deep --strict "$CONTENTS_DIRECTORY/Kayla Monitor.app"

/usr/bin/hdiutil create -srcfolder "$CONTENTS_DIRECTORY" \
    -volname "Codex Focus Monitor $VERSION" -fs HFS+ -format UDZO "$DMG_OUTPUT"
/usr/bin/hdiutil verify "$DMG_OUTPUT"
(
    cd "$PROJECT_ROOT/outputs"
    /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)
echo "$DMG_OUTPUT"
