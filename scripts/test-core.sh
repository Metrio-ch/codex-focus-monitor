#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="$PROJECT_ROOT/work/module-cache"
SWIFTPM_CACHE="$PROJECT_ROOT/work/swiftpm-cache"

mkdir -p "$MODULE_CACHE" "$SWIFTPM_CACHE"
export SDKROOT="$SDK_PATH"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

swift run --package-path "$PROJECT_ROOT" --cache-path "$SWIFTPM_CACHE" kayla-monitor-hook --self-test
