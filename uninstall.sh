#!/bin/bash
# Снимает демон с автозапуска. Конфиг и состояние не трогает.
set -uo pipefail

LABEL="com.geforester.adaptive-brightness"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "Демон снят с автозапуска."
echo "Яркость осталась там, где была — покрути вручную, если нужно."
echo
echo "Если нужно вычистить всё:"
echo "  rm -rf ~/.config/adaptive-brightness ~/.local/state/adaptive-brightness"
echo "  rm -rf ~/Applications/Adaptive\\ Brightness.app ~/.local/bin/adaptive-brightness"
