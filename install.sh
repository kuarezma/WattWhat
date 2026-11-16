#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ZIP=""
cleanup() {
    if [ -n "$TMP_ZIP" ]; then
        rm -f "$TMP_ZIP"
    fi
}
trap cleanup EXIT

echo "WattWhat Kurulumu Başlıyor..."

pkill -x WattWhat >/dev/null 2>&1 || true

if [ -d "$SCRIPT_DIR/WattWhat.app" ]; then
    echo "Yerel WattWhat.app paketi kuruluyor..."
    rm -rf /Applications/WattWhat.app
    cp -R "$SCRIPT_DIR/WattWhat.app" /Applications/WattWhat.app
elif [ -f "$SCRIPT_DIR/WattWhat.zip" ]; then
    echo "Yerel WattWhat.zip paketi kuruluyor..."
    unzip -oq "$SCRIPT_DIR/WattWhat.zip" -d /Applications
else
    echo "En güncel WattWhat paketi indiriliyor..."
    TMP_ZIP="$(mktemp /tmp/WattWhat.XXXXXX.zip)"
    curl -fsSL https://github.com/kuarezma/WattWhat/releases/latest/download/WattWhat.zip -o "$TMP_ZIP"
    unzip -oq "$TMP_ZIP" -d /Applications
fi

xattr -cr /Applications/WattWhat.app

if [ -e /Library/PrivilegedHelperTools/com.kuarezma.wattwhat.helper ]; then
    echo "ℹ️ Mevcut yardımcı servis tespit edildi. WattWhat içinden veya 'wattctl install' ile yardımcı servisi v2.1.0 sürümüne güncelleyebilirsiniz."
fi

open /Applications/WattWhat.app
echo "Kurulum başarıyla tamamlandı! Bu pencereyi kapatabilirsiniz."
