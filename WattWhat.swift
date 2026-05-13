import Cocoa
import IOKit.ps
import IOKit
import ServiceManagement
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var loginItem: NSMenuItem!
    var averageWattageItem: NSMenuItem!
    var temperatureItem: NSMenuItem!
    var topApp1Item: NSMenuItem!
    var topApp2Item: NSMenuItem!
    
    var totalWatts: Double = 0.0
    var wattSamplesCount: Int = 0
    var wasCharging: Bool = false
    var hasNotifiedFullCharge = false
    var hasNotifiedLowBattery = false
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        let menu = NSMenu()
        averageWattageItem = NSMenuItem(title: "Ortalama: -- W", action: nil, keyEquivalent: "")
        averageWattageItem.isEnabled = false
        menu.addItem(averageWattageItem)
        
        temperatureItem = NSMenuItem(title: "Pil Sıcaklığı: -- °C", action: nil, keyEquivalent: "")
        temperatureItem.isEnabled = false
        menu.addItem(temperatureItem)
        
        menu.addItem(NSMenuItem.separator())
        
        topApp1Item = NSMenuItem(title: "1. -- (0.0 W)", action: nil, keyEquivalent: "")
        topApp1Item.isEnabled = false
        menu.addItem(topApp1Item)
        
        topApp2Item = NSMenuItem(title: "2. -- (0.0 W)", action: nil, keyEquivalent: "")
        topApp2Item.isEnabled = false
        menu.addItem(topApp2Item)
        
        menu.addItem(NSMenuItem.separator())
        
        let closeAllAppsItem = NSMenuItem(title: "Tüm Uygulamaları Kapat", action: #selector(closeAllApps), keyEquivalent: "")
        let closeAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.menuFont(ofSize: 0)
        ]
        closeAllAppsItem.attributedTitle = NSAttributedString(string: "Tüm Uygulamaları Kapat", attributes: closeAttributes)
        menu.addItem(closeAllAppsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        loginItem = NSMenuItem(title: "Başlangıçta Aç", action: #selector(toggleLoginItem), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
        
        updateLoginItemState()
        updateBatteryStatus()
        
        timer = Timer.scheduledTimer(timeInterval: 3.0, target: self, selector: #selector(updateBatteryStatus), userInfo: nil, repeats: true)
    }
    
    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    @objc func closeAllApps() {
        let apps = NSWorkspace.shared.runningApplications
        let currentApp = NSRunningApplication.current
        for app in apps {
            if app.activationPolicy == .regular && app != currentApp && app.bundleIdentifier != "com.apple.Finder" {
                app.terminate()
            }
        }
    }
    
    func updateTopAppsBackground(totalWatts: Double) {
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            task.launchPath = "/bin/ps"
            task.arguments = ["-eo", "pcpu,comm", "-r"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.components(separatedBy: .newlines).dropFirst()
                    var appCPUs: [(name: String, cpu: Double)] = []
                    var totalCPU: Double = 0.0
                    
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }
                        
                        let parts = trimmed.split(separator: " ", maxSplits: 1)
                        if parts.count == 2, let cpu = Double(parts[0]) {
                            totalCPU += cpu
                            let comm = String(parts[1])
                            
                            if comm.hasPrefix("/System/") || comm.hasPrefix("/sbin/") || comm.hasPrefix("/usr/") || comm.contains("kernel_task") || comm.contains("WindowServer") || comm.contains("WattWhat") || comm.contains("launchd") {
                                continue
                            }
                            
                            let name = (comm as NSString).lastPathComponent
                            appCPUs.append((name: name, cpu: cpu))
                        }
                    }
                    
                    let sorted = appCPUs.sorted { $0.cpu > $1.cpu }
                    let top2 = Array(sorted.prefix(2))
                    let baseCPU = max(totalCPU, 1.0)
                    
                    DispatchQueue.main.async {
                        if top2.count > 0 {
                            let w1 = (top2[0].cpu / baseCPU) * totalWatts
                            self.topApp1Item.title = String(format: "1. %@ (%.1f W)", top2[0].name, w1)
                        } else {
                            self.topApp1Item.title = "1. -- (0.0 W)"
                        }
                        
                        if top2.count > 1 {
                            let w2 = (top2[1].cpu / baseCPU) * totalWatts
                            self.topApp2Item.title = String(format: "2. %@ (%.1f W)", top2[1].name, w2)
                        } else {
                            self.topApp2Item.title = "2. -- (0.0 W)"
                        }
                    }
                }
            } catch {
                print("Error getting top apps")
            }
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }
    
    @objc func toggleLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    loginItem.state = .off
                } else {
                    try SMAppService.mainApp.register()
                    loginItem.state = .on
                }
            } catch {
                print("Error toggling login item: \(error)")
            }
        } else {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.wattwhat.app"
            let isEnabled = (loginItem.state == .on)
            SMLoginItemSetEnabled(bundleID as CFString, !isEnabled)
            loginItem.state = isEnabled ? .off : .on
        }
    }
    
    func updateLoginItemState() {
        if #available(macOS 13.0, *) {
            loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        } else {
            loginItem.state = .off
        }
    }
    
    @objc func updateBatteryStatus() {
        var watts: Double = 0.0
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            if let voltageRef = IORegistryEntryCreateCFProperty(service, "Voltage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
               let amperageRef = IORegistryEntryCreateCFProperty(service, "Amperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                watts = abs(Double(voltageRef) * Double(amperageRef) / 1_000_000.0)
            }
            if let tempRef = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                let celsius = Double(tempRef) / 100.0
                let tempPrefix = "Pil Sıcaklığı: "
                let tempValue = String(format: "%.1f °C", celsius)
                
                let menuFont = NSFont.menuFont(ofSize: 0)
                
                let attrStr = NSMutableAttributedString(string: tempPrefix, attributes: [
                    .font: menuFont,
                    .foregroundColor: NSColor(calibratedWhite: 0.999, alpha: 1.0)
                ])
                let valAttrStr = NSAttributedString(string: tempValue, attributes: [
                    .font: menuFont,
                    .foregroundColor: NSColor.systemOrange
                ])
                attrStr.append(valAttrStr)
                temperatureItem.attributedTitle = attrStr
            }
            IOObjectRelease(service)
        }
        
        updateTopAppsBackground(totalWatts: watts)
        
        var isCharging = false
        var timeRemaining: Int = 0
        var isFullyCharged = false
        var percentage: Double = 0.0
        
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        
        for source in sources {
            if let info = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                let type = info[kIOPSTypeKey] as? String ?? ""
                if type != kIOPSInternalBatteryType { continue }
                
                let state = info[kIOPSPowerSourceStateKey] as? String ?? ""
                isCharging = (state == kIOPSACPowerValue)
                isFullyCharged = (info[kIOPSIsChargedKey] as? Bool) ?? false
                
                let currentCapacity = info[kIOPSCurrentCapacityKey] as? Int ?? 0
                let maxCapacity = info[kIOPSMaxCapacityKey] as? Int ?? 100
                if maxCapacity > 0 {
                    percentage = (Double(currentCapacity) / Double(maxCapacity)) * 100.0
                }
                
                if isCharging {
                    timeRemaining = info[kIOPSTimeToFullChargeKey] as? Int ?? 0
                } else {
                    timeRemaining = info[kIOPSTimeToEmptyKey] as? Int ?? 0
                }
            }
        }
        
        if isCharging != wasCharging {
            totalWatts = 0.0
            wattSamplesCount = 0
            wasCharging = isCharging
        }
        
        totalWatts += watts
        wattSamplesCount += 1
        let avg = totalWatts / Double(wattSamplesCount)
        
        let avgPrefix = isCharging ? "Ortalama Şarj: " : "Ortalama Tüketim: "
        let avgValue = String(format: "%.1f W", avg)
        
        let menuFont = NSFont.menuFont(ofSize: 0)
        
        let avgAttrStr = NSMutableAttributedString(string: avgPrefix, attributes: [
            .font: menuFont,
            .foregroundColor: NSColor(calibratedWhite: 0.999, alpha: 1.0)
        ])
        let avgValAttrStr = NSAttributedString(string: avgValue, attributes: [
            .font: menuFont,
            .foregroundColor: NSColor.systemCyan
        ])
        avgAttrStr.append(avgValAttrStr)
        averageWattageItem.attributedTitle = avgAttrStr
        
        let wattString = String(format: "%.1fW", watts)
        var timeString = ""
        
        if isFullyCharged {
            timeString = " (Dolu)"
        } else if timeRemaining > 0 && timeRemaining < 6000 {
            let hours = timeRemaining / 60
            let minutes = timeRemaining % 60
            if hours > 0 {
                timeString = " (\(hours)s \(minutes)d)"
            } else {
                timeString = " (\(minutes)d)"
            }
        } else {
            timeString = " (Hesaplanıyor...)"
        }
        
        let title = wattString + timeString
        
        if let button = statusItem.button {
            button.title = title
            let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
            
            let config = NSImage.SymbolConfiguration(paletteColors: [isCharging ? NSColor.systemGreen : NSColor.systemYellow])
            let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            symbol?.isTemplate = false
            button.image = symbol
            button.imagePosition = .imageLeft
        }
        
        if isCharging {
            hasNotifiedLowBattery = false
            if isFullyCharged && !hasNotifiedFullCharge {
                sendNotification(title: "Pil Tamamen Doldu ⚡️", body: "Pil %100 oldu, bilgisayarınızı şarjdan çekebilirsiniz.")
                hasNotifiedFullCharge = true
            }
        } else {
            hasNotifiedFullCharge = false
            if percentage <= 20.0 && percentage > 0 && !hasNotifiedLowBattery {
                sendNotification(title: "Düşük Pil Uyarısı 🔋", body: "Piliniz %\u{200B}\(Int(percentage)) değerinin altına düştü, lütfen şarja takın.")
                hasNotifiedLowBattery = true
            } else if percentage > 20.0 {
                hasNotifiedLowBattery = false
            }
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(macOS 14.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
