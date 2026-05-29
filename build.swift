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
print("🛠 Compiling WattWhat.swift...")
run("swiftc WattWhat.swift -o WattWhat.app/Contents/MacOS/WattWhat")

// 3. Create a ZIP archive
print("📦 Creating ZIP archive...")
run("zip -r WattWhat.zip WattWhat.app")

// 4. Create a DMG disk image
print("💿 Creating DMG disk image...")
run("rm -rf DMGStaging WattWhat.dmg")
run("mkdir -p DMGStaging")
run("cp -r WattWhat.app DMGStaging/")
run("ln -s /Applications DMGStaging/Applications")
run("hdiutil create -volname 'WattWhat' -srcfolder DMGStaging -ov -format UDZO WattWhat.dmg")
run("rm -rf DMGStaging")

print("✅ Build Process Completed Successfully!")
print("📂 Outputs: WattWhat.app, WattWhat.zip, WattWhat.dmg")
