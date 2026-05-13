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
        averageWattageItem.isEnabled = false // So it looks like a non-clickable info item
        menu.addItem(averageWattageItem)
        
        temperatureItem = NSMenuItem(title: "Pil Sıcaklığı: -- °C", action: nil, keyEquivalent: "")
        temperatureItem.isEnabled = false
        menu.addItem(temperatureItem)
        
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
                temperatureItem.title = String(format: "Pil Sıcaklığı: %.1f °C", celsius)
            }
            IOObjectRelease(service)
        }
        
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
        
        if isCharging {
            averageWattageItem.title = String(format: "Ortalama Şarj: %.1f W", avg)
        } else {
            averageWattageItem.title = String(format: "Ortalama Tüketim: %.1f W", avg)
        }
        
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
