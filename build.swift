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

print("⚡️ Starting WattWhat Build Process...")

// 1. Ensure the App bundle structure exists
run("mkdir -p WattWhat.app/Contents/MacOS")

// 2. Compile the Swift file
print("🛠 Compiling WattWhat sources...")
run("swiftc WattWhat.swift Sources/WattWhatCore/*.swift Sources/WattWhatUI/*.swift -o WattWhat.app/Contents/MacOS/WattWhat")

// 2b. Write Info.plist — without a bundle identifier UNUserNotificationCenter
//     throws at launch; LSUIElement keeps it a menu-bar-only agent (no Dock icon).
let appVersion = "1.6.0"
let infoPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>WattWhat</string>
    <key>CFBundleDisplayName</key>
    <string>WattWhat</string>
    <key>CFBundleExecutable</key>
    <string>WattWhat</string>
    <key>CFBundleIdentifier</key>
    <string>com.kuarezma.wattwhat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>\(appVersion)</string>
    <key>CFBundleVersion</key>
    <string>\(appVersion)</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
"""
try? infoPlist.write(to: URL(fileURLWithPath: "WattWhat.app/Contents/Info.plist"), atomically: true, encoding: .utf8)

// 3. Codesign the app to prevent some Gatekeeper errors
print("✍️ Codesigning the App...")
run("codesign --force --deep -s - WattWhat.app")

// 4. Create a ZIP archive
print("📦 Creating ZIP archive...")
run("zip -r WattWhat.zip WattWhat.app")

// 5. Create a PKG installer
print("📦 Creating PKG installer...")
run("pkgbuild --root WattWhat.app --identifier com.kuarezma.wattwhat --version 1.6.0 --install-location /Applications/WattWhat.app WattWhat.pkg")

// 6. Create a DMG disk image
print("💿 Creating DMG disk image...")
run("rm -rf DMGStaging WattWhat.dmg")
run("mkdir -p DMGStaging")
run("cp -r WattWhat.app DMGStaging/")
run("ln -s /Applications DMGStaging/Applications")
run("hdiutil create -volname 'WattWhat' -srcfolder DMGStaging -ov -format UDZO WattWhat.dmg")
run("rm -rf DMGStaging")

// 7. Create Install Command script
print("📜 Creating Install Script...")
let installScript = """
#!/bin/bash
echo "WattWhat Kurulumu Başlıyor..."
echo "Lütfen bekleyin..."
curl -sL https://github.com/kuarezma/WattWhat/releases/latest/download/WattWhat.zip -o /tmp/WattWhat.zip
unzip -oq /tmp/WattWhat.zip -d /Applications
xattr -cr /Applications/WattWhat.app
rm /tmp/WattWhat.zip
open /Applications/WattWhat.app
echo "Kurulum başarıyla tamamlandı! Bu pencereyi kapatabilirsiniz."
"""
let scriptURL = URL(fileURLWithPath: "Yukle_WattWhat.command")
try? installScript.write(to: scriptURL, atomically: true, encoding: .utf8)
run("chmod +x Yukle_WattWhat.command")

print("✅ Build Process Completed Successfully!")
print("📂 Outputs: WattWhat.app, WattWhat.zip, WattWhat.dmg, WattWhat.pkg, Yukle_WattWhat.command")
