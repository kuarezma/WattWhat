#!/bin/bash
set -euo pipefail

TMP_ZIP="$(mktemp /tmp/WattWhat.XXXXXX.zip)"
trap 'rm -f "$TMP_ZIP"' EXIT

echo "WattWhat Kurulumu Başlıyor..."
echo "Lütfen bekleyin..."
curl -fsSL https://github.com/kuarezma/WattWhat/releases/latest/download/WattWhat.zip -o "$TMP_ZIP"
pkill -x WattWhat >/dev/null 2>&1 || true
unzip -oq "$TMP_ZIP" -d /Applications
xattr -cr /Applications/WattWhat.app
if [ -e /Library/PrivilegedHelperTools/com.kuarezma.wattwhat.helper ]; then
    echo "ℹ️ Mevcut yardımcı servis tespit edildi. WattWhat içinden veya 'wattctl install' ile yardımcı servisi v2.1.0 sürümüne güncelleyebilirsiniz."
fi
open /Applications/WattWhat.app
echo "Kurulum başarıyla tamamlandı! Bu pencereyi kapatabilirsiniz."