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

SIGN_ID="Adaptive Brightness Self-Signed"

# Заводит самоподписанный сертификат для подписи, если его ещё нет.
# Одноразовая операция: дальше он просто лежит в связке ключей.
ensure_signing_identity() {
    if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
        return 0
    fi
    echo "    сертификата нет — создаю (один раз на машину)"
    local tmp pw
    tmp="$(mktemp -d)"
    pw="adaptive-brightness-import"
    openssl req -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -x509 -days 3650 \
        -out "$tmp/cert.pem" -subj "/CN=$SIGN_ID" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
    # Security.framework не читает PKCS#12 с дефолтными алгоритмами OpenSSL 3,
    # а пустой пароль ломает импорт — отсюда и -keypbe, и непустой pass.
    openssl pkcs12 -export -out "$tmp/id.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -passout "pass:$pw" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 >/dev/null 2>&1
    security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P "$pw" -T /usr/bin/codesign
    rm -rf "$tmp"
}

# Перезапись бинаря под работающим процессом ломает его подпись на лету:
# macOS отбирает у живой сессии захвата права (ScreenCaptureKit отвечает
# ошибкой 1004), а следующий запуск какое-то время получает отказы TCC.
# Поэтому останавливаем демон на время сборки и поднимаем обратно.
LABEL="com.geforester.adaptive-brightness"
WAS_RUNNING=0
if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
    WAS_RUNNING=1
    echo "==> Останавливаю демон на время сборки"
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
    sleep 1
fi
restore_daemon() {
    [ "$WAS_RUNNING" = "1" ] || return 0
    echo "==> Поднимаю демон обратно"
    launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || true
}
trap restore_daemon EXIT

mkdir -p "$APP/Contents/MacOS" "$BIN_DIR"

echo "==> Компиляция"
swiftc -O \
    -framework ScreenCaptureKit \
    -framework AppKit \
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

# Подпись стабильным самоподписанным сертификатом.
#
# Ad-hoc подпись (`--sign -`) прописывает в designated requirement cdhash
# бандла, а он меняется при каждой сборке. macOS видит новое приложение и
# сбрасывает выданное Screen Recording. Со своим сертификатом requirement
# выглядит как `identifier "..." and certificate leaf = H"..."` и от содержимого
# бандла не зависит — разрешение переживает пересборки.
echo "==> Подпись"
ensure_signing_identity
if ! codesign --force --sign "$SIGN_ID" \
        --identifier com.geforester.adaptive-brightness \
        "$APP" 2>/dev/null; then
    echo "    ВНИМАНИЕ: подписать своим сертификатом не вышло (связка ключей заперта?)."
    echo "    Откатываюсь на ad-hoc — сборка будет рабочей, но Screen Recording"
    echo "    после неё придётся выдать заново через ./reauthorize.sh"
    codesign --force --sign - --identifier com.geforester.adaptive-brightness "$APP"
fi

# CLI-обёртка. Симлинк резолвится в бинарь внутри бандла, поэтому команды
# из терминала работают под тем же разрешением, что и демон.
ln -sf "$APP/Contents/MacOS/adaptive-brightness" "$BIN_DIR/adaptive-brightness"

echo "==> Готово"
echo "    бандл: $APP"
echo "    cli:   $BIN_DIR/adaptive-brightness"
