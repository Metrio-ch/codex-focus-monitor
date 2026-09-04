#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DESTINATION="$HOME/Applications/Kayla Monitor.app"
SUPPORT_DIRECTORY="$HOME/Library/Application Support/Kayla Monitor"
HELPER_DESTINATION="$SUPPORT_DIRECTORY/bin/kayla-monitor-hook"
HOOKS_FILE="$HOME/.codex/hooks.json"
BACKUP_DIRECTORY="$SUPPORT_DIRECTORY/backups/hooks"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TRASH_DESTINATION="$HOME/.Trash/Kayla Monitor Uninstall $STAMP"

/usr/bin/python3 "$SCRIPT_DIRECTORY/hooks_config.py" uninstall \
    --hooks "$HOOKS_FILE" \
    --helper "$HELPER_DESTINATION" \
    --backup-dir "$BACKUP_DIRECTORY"

mkdir -p "$TRASH_DESTINATION"
if [[ -e "$APP_DESTINATION" ]]; then
    mv "$APP_DESTINATION" "$TRASH_DESTINATION/Kayla Monitor.app"
fi
if [[ -e "$SUPPORT_DIRECTORY" ]]; then
    mv "$SUPPORT_DIRECTORY" "$TRASH_DESTINATION/Application Support"
fi

echo "Kayla Monitor moved to $TRASH_DESTINATION"

