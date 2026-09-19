#!/bin/bash
# Собирает .app-бандл и кладёт CLI-симлинк в ~/.local/bin.
#
# Бандл, а не голый бинарь, нужен из-за TCC: разрешение Screen Recording
# выдаётся приложению с bundle identifier. Голый бинарь, запущенный из launchd,
# промпт не показывает и вручную в список «Запись экрана» не добавляется.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/Adaptive Brightness.app"
BIN_DIR="$HOME/.local/bin"

mkdir -p "$APP/Contents/MacOS" "$BIN_DIR"

echo "==> Компиляция"
swiftc -O \
    -framework ScreenCaptureKit \
    -o "$APP/Contents/MacOS/adaptive-brightness" \
    "$ROOT/src/main.swift"

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>adaptive-brightness</string>
    <key>CFBundleIdentifier</key>
    <string>com.geforester.adaptive-brightness</string>
    <key>CFBundleName</key>
    <string>Adaptive Brightness</string>
    <key>CFBundleDisplayName</key>
    <string>Adaptive Brightness</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Агент без иконки в доке и без меню-бара. -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLISTEOF

# Ad-hoc подпись со стабильным identifier: без неё macOS считает бандл
# незнакомым после каждой пересборки и сбрасывает выданное разрешение.
echo "==> Подпись"
codesign --force --sign - \
    --identifier com.geforester.adaptive-brightness \
    "$APP"

# CLI-обёртка. Симлинк резолвится в бинарь внутри бандла, поэтому команды
# из терминала работают под тем же разрешением, что и демон.
ln -sf "$APP/Contents/MacOS/adaptive-brightness" "$BIN_DIR/adaptive-brightness"

echo "==> Готово"
echo "    бандл: $APP"
echo "    cli:   $BIN_DIR/adaptive-brightness"
