#!/bin/bash
set -euo pipefail

TMP_DIR="$(mktemp -d /tmp/WattWhat.XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

TMP_ZIP="$TMP_DIR/WattWhat.zip"
STAGE_DIR="$TMP_DIR/stage"

echo "WattWhat Kurulumu Başlıyor..."
echo "Lütfen bekleyin..."
curl -fsSL https://github.com/kuarezma/WattWhat/releases/latest/download/WattWhat.zip -o "$TMP_ZIP"

mkdir -p "$STAGE_DIR"
unzip -oq "$TMP_ZIP" -d "$STAGE_DIR"

if [ ! -f "$STAGE_DIR/WattWhat.app/Contents/Info.plist" ]; then
    echo "❌ İndirilen pakette WattWhat.app/Contents/Info.plist bulunamadı." >&2
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