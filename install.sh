#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d /tmp/WattWhat.XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

STAGE_DIR="$TMP_DIR/stage"
TMP_ZIP="$TMP_DIR/WattWhat.zip"
mkdir -p "$STAGE_DIR"

echo "WattWhat Kurulumu Başlıyor..."

if [ -d "$SCRIPT_DIR/WattWhat.app" ]; then
    echo "Yerel WattWhat.app paketi doğrulanıyor..."
    cp -R "$SCRIPT_DIR/WattWhat.app" "$STAGE_DIR/WattWhat.app"
elif [ -f "$SCRIPT_DIR/WattWhat.zip" ]; then
    echo "Yerel WattWhat.zip paketi doğrulanıyor..."
    unzip -oq "$SCRIPT_DIR/WattWhat.zip" -d "$STAGE_DIR"
else
    echo "En güncel WattWhat paketi indiriliyor..."
    curl -fsSL https://github.com/kuarezma/WattWhat/releases/latest/download/WattWhat.zip -o "$TMP_ZIP"
    unzip -oq "$TMP_ZIP" -d "$STAGE_DIR"
fi

if [ ! -f "$STAGE_DIR/WattWhat.app/Contents/Info.plist" ]; then
    echo "❌ Pakette WattWhat.app/Contents/Info.plist bulunamadı." >&2
    exit 1
fi

codesign --verify --deep --strict "$STAGE_DIR/WattWhat.app"

pkill -x WattWhat >/dev/null 2>&1 || true
for _ in $(seq 1 25); do
    pgrep -x WattWhat >/dev/null 2>&1 || break
    sleep 0.2
done
sleep 0.3
rm -rf /Applications/WattWhat.app
mv "$STAGE_DIR/WattWhat.app" /Applications/WattWhat.app
xattr -cr /Applications/WattWhat.app

if [ -e /Library/PrivilegedHelperTools/com.kuarezma.wattwhat.helper ]; then
    echo "ℹ️ Mevcut yardımcı servis tespit edildi. WattWhat içinden veya 'wattctl install' ile yardımcı servisi v2.1.0 sürümüne güncelleyebilirsiniz."
fi

open /Applications/WattWhat.app
echo "Kurulum başarıyla tamamlandı! Bu pencereyi kapatabilirsiniz."
