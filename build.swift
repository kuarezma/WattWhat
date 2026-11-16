#!/usr/bin/env swift

import Foundation

func run(_ command: String) {
    print("⏳ Running: \(command)")
    let task = Process()
    task.launchPath = "/bin/sh"
    task.arguments = ["-c", command]
    task.launch()
    task.waitUntilExit()
    if task.terminationStatus != 0 {
        print("❌ Error executing command: \(command)")
        exit(1)
    }
}

let appVersion = "2.1.0"
print("⚡️ Starting WattWhat v\(appVersion) Build Process...")

// 1. Ensure the App bundle structure exists
run("mkdir -p WattWhat.app/Contents/MacOS WattWhat.app/Contents/Resources")

// 2. Compile the main WattWhat menu bar app
print("🛠 Compiling WattWhat app...")
run("swiftc -O WattWhat.swift Sources/WattWhatCore/*.swift Sources/WattWhatUI/*.swift -o WattWhat.app/Contents/MacOS/WattWhat")

// 3. Compile the privileged SMC power helper daemon
print("🛠 Compiling wattwhat-helper...")
run("swiftc -O Sources/WattWhatCore/*.swift Sources/WattWhatHelper/main.swift -o WattWhat.app/Contents/MacOS/wattwhat-helper")

// 4. Compile the wattctl CLI tool
print("🛠 Compiling wattctl CLI...")
run("swiftc -O Sources/WattWhatCore/*.swift Sources/WattWhatCLI/main.swift -o WattWhat.app/Contents/MacOS/wattctl")

// 5. Copy AppIcon if present
if FileManager.default.fileExists(atPath: "Assets/AppIcon.icns") {
    run("cp -f Assets/AppIcon.icns WattWhat.app/Contents/Resources/AppIcon.icns")
}

// 6. Copy Info.plist from Assets/Info.plist (single source of truth) and enforce version
run("cp -f Assets/Info.plist WattWhat.app/Contents/Info.plist")
run("/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString \(appVersion)' WattWhat.app/Contents/Info.plist")
run("/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion \(appVersion)' WattWhat.app/Contents/Info.plist")
run("plutil -lint WattWhat.app/Contents/Info.plist >/dev/null")

// 7. Codesign the app to prevent Gatekeeper errors
print("✍️ Codesigning the App...")
run("codesign --force --deep -s - WattWhat.app")

// 8. Create a ZIP archive
print("📦 Creating ZIP archive...")
run("rm -f WattWhat.zip && zip -rq WattWhat.zip WattWhat.app")

// 9. Create a PKG installer
print("📦 Creating PKG installer...")
run("pkgbuild --root WattWhat.app --identifier com.kuarezma.wattwhat --version \(appVersion) --install-location /Applications/WattWhat.app WattWhat.pkg")

// 10. Create a DMG disk image
print("💿 Creating DMG disk image...")
run("rm -rf DMGStaging WattWhat.dmg")
run("mkdir -p DMGStaging")
run("cp -r WattWhat.app DMGStaging/")
run("ln -s /Applications DMGStaging/Applications")
run("hdiutil create -volname 'WattWhat' -srcfolder DMGStaging -ov -format UDZO WattWhat.dmg")
run("rm -rf DMGStaging")

// 11. Create Install Command script
print("📜 Creating Install Script...")
let installScript = """
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
rm -rf /Applications/WattWhat.app
mv "$STAGE_DIR/WattWhat.app" /Applications/WattWhat.app
xattr -cr /Applications/WattWhat.app

if [ -e /Library/PrivilegedHelperTools/com.kuarezma.wattwhat.helper ]; then
    echo "ℹ️ Mevcut yardımcı servis tespit edildi. WattWhat içinden veya 'wattctl install' ile yardımcı servisi v\(appVersion) sürümüne güncelleyebilirsiniz."
fi
open /Applications/WattWhat.app
echo "Kurulum başarıyla tamamlandı! Bu pencereyi kapatabilirsiniz."
"""
let scriptURL = URL(fileURLWithPath: "Yukle_WattWhat.command")
try? installScript.write(to: scriptURL, atomically: true, encoding: .utf8)
run("chmod +x Yukle_WattWhat.command")

print("✅ Build Process Completed Successfully!")
print("📂 Outputs: WattWhat.app (+ wattwhat-helper, wattctl), WattWhat.zip, WattWhat.dmg, WattWhat.pkg, Yukle_WattWhat.command")
