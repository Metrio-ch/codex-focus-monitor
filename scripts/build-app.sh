#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
OUTPUT_DIRECTORY="$PROJECT_ROOT/outputs"
APP_OUTPUT="$OUTPUT_DIRECTORY/Kayla Monitor.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="$PROJECT_ROOT/work/module-cache"
SWIFTPM_CACHE="$PROJECT_ROOT/work/swiftpm-cache"

mkdir -p "$MODULE_CACHE" "$SWIFTPM_CACHE"
export SDKROOT="$SDK_PATH"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

swift build --package-path "$PROJECT_ROOT" -c release --cache-path "$SWIFTPM_CACHE" \
    -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_ROOT=/src/codex-focus-monitor" \
    -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_ROOT=/src/codex-focus-monitor"
BINARY_DIRECTORY="$(swift build --package-path "$PROJECT_ROOT" -c release --cache-path "$SWIFTPM_CACHE" --show-bin-path)"

STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/kayla-monitor-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
STAGED_APP="$STAGING_DIRECTORY/Kayla Monitor.app"

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Helpers"
cp "$PROJECT_ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$BINARY_DIRECTORY/KaylaMonitor" "$STAGED_APP/Contents/MacOS/KaylaMonitor"
cp "$BINARY_DIRECTORY/kayla-monitor-hook" "$STAGED_APP/Contents/Helpers/kayla-monitor-hook"
chmod 755 "$STAGED_APP/Contents/MacOS/KaylaMonitor" "$STAGED_APP/Contents/Helpers/kayla-monitor-hook"

# Remove local debug information before signing a distributable application.
/usr/bin/strip -S "$STAGED_APP/Contents/MacOS/KaylaMonitor" "$STAGED_APP/Contents/Helpers/kayla-monitor-hook"
if LC_ALL=C /usr/bin/grep -a -l -F "$HOME/" \
    "$STAGED_APP/Contents/MacOS/KaylaMonitor" "$STAGED_APP/Contents/Helpers/kayla-monitor-hook"; then
    echo "拒绝发布：二进制仍含当前用户的主目录路径" >&2
    exit 1
fi

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$STAGED_APP"

mkdir -p "$OUTPUT_DIRECTORY"
case "$APP_OUTPUT" in
    "$PROJECT_ROOT"/outputs/*) ;;
    *) echo "拒绝覆盖非 outputs 路径" >&2; exit 1 ;;
esac
rm -rf "$APP_OUTPUT"
mv "$STAGED_APP" "$APP_OUTPUT"

echo "$APP_OUTPUT"
