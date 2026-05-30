#!/bin/bash
echo "WattWhat Kurulumu Başlıyor..."
echo "Lütfen bekleyin..."
curl -sL https://github.com/kuarezma/WattWhat/releases/latest/download/WattWhat.zip -o /tmp/WattWhat.zip
unzip -oq /tmp/WattWhat.zip -d /Applications
xattr -cr /Applications/WattWhat.app
rm /tmp/WattWhat.zip
open /Applications/WattWhat.app
echo "Kurulum başarıyla tamamlandı! Bu pencereyi kapatabilirsiniz."