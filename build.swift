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

print("⚡️ Starting WattWhat v2.0 Build Process...")

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

// 6. Write Info.plist — without a bundle identifier UNUserNotificationCenter
//     throws at launch; LSUIElement keeps it a menu-bar-only agent (no Dock icon).
let appVersion = "2.0.0"
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
print("📂 Outputs: WattWhat.app (+ wattwhat-helper, wattctl), WattWhat.zip, WattWhat.dmg, WattWhat.pkg, Yukle_WattWhat.command")
