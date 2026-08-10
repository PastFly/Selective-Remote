#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/dist/Selective Remote.app"
TARGET_APP="/Applications/Selective Remote.app"

chmod +x "$ROOT/scripts/build_app.sh"
"$ROOT/scripts/build_app.sh"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Ошибка: сборка не создала $SOURCE_APP" >&2
    exit 1
fi

osascript -e 'tell application "Selective Remote" to quit' 2>/dev/null || true
sleep 1

if [[ -d "$TARGET_APP" ]]; then
    BACKUP_APP="$HOME/.Trash/Selective Remote-$(date +%Y%m%d-%H%M%S)-$$.app"
    mv "$TARGET_APP" "$BACKUP_APP"
    echo "Предыдущая версия сохранена: $BACKUP_APP"
fi

ditto "$SOURCE_APP" "$TARGET_APP"
open "$TARGET_APP"

echo "Установлено: $TARGET_APP"
