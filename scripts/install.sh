#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
APP_SOURCE="$PROJECT_ROOT/outputs/Kayla Monitor.app"
APP_DESTINATION="$HOME/Applications/Kayla Monitor.app"
SUPPORT_DIRECTORY="$HOME/Library/Application Support/Kayla Monitor"
HELPER_DESTINATION="$SUPPORT_DIRECTORY/bin/kayla-monitor-hook"
HOOKS_FILE="$HOME/.codex/hooks.json"
BACKUP_DIRECTORY="$SUPPORT_DIRECTORY/backups"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

"$SCRIPT_DIRECTORY/build-app.sh"
test -d "$APP_SOURCE"
test -x "$APP_SOURCE/Contents/Helpers/kayla-monitor-hook"

mkdir -p "$HOME/Applications" "$SUPPORT_DIRECTORY/bin" "$BACKUP_DIRECTORY/apps" "$BACKUP_DIRECTORY/hooks"
chmod 700 "$SUPPORT_DIRECTORY" "$SUPPORT_DIRECTORY/bin" "$BACKUP_DIRECTORY" "$BACKUP_DIRECTORY/apps" "$BACKUP_DIRECTORY/hooks"

if [[ -e "$APP_DESTINATION" ]]; then
    mv "$APP_DESTINATION" "$BACKUP_DIRECTORY/apps/Kayla Monitor-$STAMP.app"
fi
/usr/bin/ditto "$APP_SOURCE" "$APP_DESTINATION"
/usr/bin/install -m 755 "$APP_SOURCE/Contents/Helpers/kayla-monitor-hook" "$HELPER_DESTINATION"

/usr/bin/python3 "$SCRIPT_DIRECTORY/hooks_config.py" install \
    --hooks "$HOOKS_FILE" \
    --helper "$HELPER_DESTINATION" \
    --backup-dir "$BACKUP_DIRECTORY/hooks"

/usr/bin/open "$APP_DESTINATION"
echo "Kayla Monitor installed at $APP_DESTINATION"
