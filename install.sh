#!/bin/bash
# Регистрирует демон в launchd (автозапуск при входе в систему).
set -euo pipefail

LABEL="com.geforester.adaptive-brightness"
APP="$HOME/Applications/Adaptive Brightness.app"
BIN="$APP/Contents/MacOS/adaptive-brightness"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/.local/state/adaptive-brightness"

if [[ ! -x "$BIN" ]]; then
    echo "Бинарь не собран. Сначала: ./build.sh" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$STATE_DIR"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <!-- Interactive, не Background: Background отдаёт процесс во власть
         launchd-троттлинга и укрупнения таймеров, и контур на 30 Гц реально
         тикает на 9. Замерено: PRI 4 и 108 мс на такт против 37 и 39 мс. -->
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$STATE_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$STATE_DIR/launchd.err.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"

echo "Демон зарегистрирован: $LABEL"
echo "Лог:  $STATE_DIR/daemon.log"
echo
echo "Проверь через несколько секунд:  adaptive-brightness status"
