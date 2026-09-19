#!/bin/bash
# Переавторизация после пересборки.
#
# Ad-hoc подпись меняет cdhash бандла при каждой сборке, и macOS считает его
# новым приложением — ранее выданное Screen Recording сбрасывается. Настройки
# демона живут в config.json и пересборки не требуют, так что это нужно только
# после правок кода.
set -uo pipefail

LABEL="com.geforester.adaptive-brightness"
APP="$HOME/Applications/Adaptive Brightness.app"

echo "==> Останавливаю демон"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
pkill -f "Adaptive Brightness.app/Contents/MacOS" 2>/dev/null

echo "==> Сбрасываю прежний вердикт TCC"
tccutil reset ScreenCapture "$LABEL"

echo "==> Запускаю приложение — сейчас появится запрос на запись экрана"
open -a "$APP"

echo
echo "Разреши запись экрана в появившемся окне, затем выполни:"
echo "    ./install.sh"
