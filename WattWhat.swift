import Cocoa
import IOKit.ps
import IOKit
import ServiceManagement
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    let appVersion = "1.5.0"
    var statusItem: NSStatusItem!
    var timer: Timer?
    var loginItem: NSMenuItem!
    var averageWattageItem: NSMenuItem!
    var temperatureItem: NSMenuItem!
    var cpuTemperatureItem: NSMenuItem!
    var topApp1Item: NSMenuItem!
    var topApp2Item: NSMenuItem!
    var topApp3Item: NSMenuItem!
    var screenOnTimeItem: NSMenuItem!
    var batteryHealthItem: NSMenuItem!
    
    var showWattItem: NSMenuItem!
    var showPercentageItem: NSMenuItem!
    var showTimeItem: NSMenuItem!
    
    let cpuTempReader = CPUTemperatureReader()
    
    var showWattInMenu: Bool {
        get { UserDefaults.standard.object(forKey: "showWattInMenu") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showWattInMenu") }
    }
    var showPercentageInMenu: Bool {
        get { UserDefaults.standard.object(forKey: "showPercentageInMenu") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showPercentageInMenu") }
    }
    var showTimeInMenu: Bool {
        get { UserDefaults.standard.object(forKey: "showTimeInMenu") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showTimeInMenu") }
    }
    
    var screenOnTime: TimeInterval {
        get { UserDefaults.standard.double(forKey: "screenOnTime") }
        set { UserDefaults.standard.set(newValue, forKey: "screenOnTime") }
    }
    var isScreenOn: Bool = true
    var lastUpdateDate: Date = Date()
    
    var totalWatts: Double = 0.0
    var wattSamplesCount: Int = 0
    var wasCharging: Bool = false
    var hasNotifiedFullCharge = false
    var hasNotifiedLowBattery = false
    var hasNotifiedEightyPercent = false
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        let menu = NSMenu()
        
        batteryHealthItem = NSMenuItem(title: "Pil Sağlığı: --", action: #selector(dummyAction), keyEquivalent: "")
        batteryHealthItem.target = self
        menu.addItem(batteryHealthItem)
        
        averageWattageItem = NSMenuItem(title: "Ortalama: -- W", action: #selector(dummyAction), keyEquivalent: "")
        averageWattageItem.target = self
        menu.addItem(averageWattageItem)
        
        temperatureItem = NSMenuItem(title: "Pil Sıcaklığı: -- °C", action: #selector(dummyAction), keyEquivalent: "")
        temperatureItem.target = self
        menu.addItem(temperatureItem)
        
        cpuTemperatureItem = NSMenuItem(title: "İşlemci Sıcaklığı: -- °C", action: #selector(dummyAction), keyEquivalent: "")
        cpuTemperatureItem.target = self
        menu.addItem(cpuTemperatureItem)
        
        screenOnTimeItem = NSMenuItem(title: "Ekran Süresi: --", action: #selector(dummyAction), keyEquivalent: "")
        screenOnTimeItem.target = self
        menu.addItem(screenOnTimeItem)
        
        menu.addItem(NSMenuItem.separator())
        
        topApp1Item = NSMenuItem(title: "1. -- (0.0 W)", action: nil, keyEquivalent: "")
        topApp1Item.isEnabled = false
        menu.addItem(topApp1Item)
        
        topApp2Item = NSMenuItem(title: "2. -- (0.0 W)", action: nil, keyEquivalent: "")
        topApp2Item.isEnabled = false
        menu.addItem(topApp2Item)
        
        topApp3Item = NSMenuItem(title: "3. -- (0.0 W)", action: nil, keyEquivalent: "")
        topApp3Item.isEnabled = false
        menu.addItem(topApp3Item)
        
        menu.addItem(NSMenuItem.separator())
        
        let closeAllAppsItem = NSMenuItem(title: "Tüm Uygulamaları Kapat", action: #selector(closeAllApps), keyEquivalent: "")
        let closeAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.menuFont(ofSize: 0)
        ]
        closeAllAppsItem.attributedTitle = NSAttributedString(string: "Tüm Uygulamaları Kapat", attributes: closeAttributes)
        menu.addItem(closeAllAppsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let appearanceMenu = NSMenu()
        showWattItem = NSMenuItem(title: "Watt Göster", action: #selector(toggleShowWatt), keyEquivalent: "")
        showPercentageItem = NSMenuItem(title: "Yüzde Göster", action: #selector(toggleShowPercentage), keyEquivalent: "")
        showTimeItem = NSMenuItem(title: "Süre Göster", action: #selector(toggleShowTime), keyEquivalent: "")
        appearanceMenu.addItem(showWattItem)
        appearanceMenu.addItem(showPercentageItem)
        appearanceMenu.addItem(showTimeItem)
        
        let appearanceMenuItem = NSMenuItem(title: "Görünüm Seçenekleri", action: nil, keyEquivalent: "")
        appearanceMenuItem.submenu = appearanceMenu
        menu.addItem(appearanceMenuItem)
        
        let openBatterySettingsItem = NSMenuItem(title: "Pil Ayarlarını Aç", action: #selector(openBatterySettings), keyEquivalent: "")
        menu.addItem(openBatterySettingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        loginItem = NSMenuItem(title: "Başlangıçta Aç", action: #selector(toggleLoginItem), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Çıkış", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        lastUpdateDate = Date()
        
        updateAppearanceMenuState()
        updateLoginItemState()
        updateBatteryStatus()
        
        checkForUpdates()
        
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
    
    func isVersionGreater(_ remote: String, _ local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(remoteParts.count, localParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
    
    func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/kuarezma/WattWhat/releases/latest") else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let data = data, error == nil else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let tagName = json["tag_name"] as? String {
                    let remoteVersion = tagName.replacingOccurrences(of: "v", with: "")
                    if let current = self?.appVersion, self?.isVersionGreater(remoteVersion, current) == true {
                        DispatchQueue.main.async {
                            self?.showUpdateAlert(newVersion: tagName)
                        }
                    }
                }
            } catch {
                print("Failed to parse update info.")
            }
        }
        task.resume()
    }
    
    func showUpdateAlert(newVersion: String) {
        let alert = NSAlert()
        alert.messageText = "Yeni Güncelleme Mevcut! 🚀"
        alert.informativeText = "WattWhat'ın yeni sürümü (\(newVersion)) çıktı. Şimdi güncellemek ister misiniz?\\n\\nGüncelle işlemi arka planda sessizce indirilecek ve uygulama yeniden başlatılacaktır."
        alert.addButton(withTitle: "Güncelle")
        alert.addButton(withTitle: "Daha Sonra")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performSilentUpdate()
        }
    }
    
    func performSilentUpdate() {
        let script = "nohup bash -c 'sleep 2 && curl -sL https://github.com/kuarezma/WattWhat/releases/latest/download/WattWhat.zip -o /tmp/WattWhat.zip && unzip -oq /tmp/WattWhat.zip -d /Applications && rm /tmp/WattWhat.zip && open /Applications/WattWhat.app' > /dev/null 2>&1 &"
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            print("Failed to run update script")
        }
        NSApplication.shared.terminate(nil)
    }
    
    @objc func screenDidSleep() { isScreenOn = false }
    @objc func screenDidWake() { 
        isScreenOn = true
        lastUpdateDate = Date()
    }
    
    func formatTimeInterval(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return String(format: "%ds %02dd", hours, minutes)
        } else {
            return String(format: "%dd", minutes)
        }
    }
    
    @objc func dummyAction(_ sender: Any?) {}
    
    @objc func toggleShowWatt() {
        showWattInMenu.toggle()
        updateAppearanceMenuState()
        updateBatteryStatus()
    }
    
    @objc func toggleShowPercentage() {
        showPercentageInMenu.toggle()
        updateAppearanceMenuState()
        updateBatteryStatus()
    }
    
    @objc func toggleShowTime() {
        showTimeInMenu.toggle()
        updateAppearanceMenuState()
        updateBatteryStatus()
    }
    
    func updateAppearanceMenuState() {
        showWattItem.state = showWattInMenu ? .on : .off
        showPercentageItem.state = showPercentageInMenu ? .on : .off
        showTimeItem.state = showTimeInMenu ? .on : .off
    }
    
    @objc func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            NSWorkspace.shared.open(url)
        }
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
                    var appTotals: [String: Double] = [:]
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
                            
                            let baseName = (comm as NSString).lastPathComponent
                            
                            var appName = baseName
                            if let range = appName.range(of: " Helper", options: .caseInsensitive) {
                                appName = String(appName[..<range.lowerBound])
                            }
                            appName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if appName.isEmpty { appName = baseName }
                            
                            appTotals[appName, default: 0.0] += cpu
                        }
                    }
                    
                    let appCPUs = appTotals.map { (name: $0.key, cpu: $0.value) }
                    let sorted = appCPUs.sorted { $0.cpu > $1.cpu }
                    let top3 = Array(sorted.prefix(3))
                    let baseCPU = max(totalCPU, 1.0)
                    
                    DispatchQueue.main.async {
                        if top3.count > 0 {
                            let w1 = (top3[0].cpu / baseCPU) * totalWatts
                            self.topApp1Item.title = String(format: "1. %@ (%.1f W)", top3[0].name, w1)
                        } else {
                            self.topApp1Item.title = "1. -- (0.0 W)"
                        }
                        
                        if top3.count > 1 {
                            let w2 = (top3[1].cpu / baseCPU) * totalWatts
                            self.topApp2Item.title = String(format: "2. %@ (%.1f W)", top3[1].name, w2)
                        } else {
                            self.topApp2Item.title = "2. -- (0.0 W)"
                        }
                        
                        if top3.count > 2 {
                            let w3 = (top3[2].cpu / baseCPU) * totalWatts
                            self.topApp3Item.title = String(format: "3. %@ (%.1f W)", top3[2].name, w3)
                        } else {
                            self.topApp3Item.title = "3. -- (0.0 W)"
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
        let now = Date()
        let delta = now.timeIntervalSince(lastUpdateDate)
        lastUpdateDate = now
        
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
                    .foregroundColor: NSColor.textColor
                ])
                let valAttrStr = NSAttributedString(string: tempValue, attributes: [
                    .font: menuFont,
                    .foregroundColor: NSColor.systemOrange
                ])
                attrStr.append(valAttrStr)
                temperatureItem.attributedTitle = attrStr
            }
            
            var cycleCount = 0
            var designCapacity = 0
            var maxCapacityFromSmart = 0

            if let cycleRef = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                cycleCount = cycleRef
            }
            if let designRef = IORegistryEntryCreateCFProperty(service, "DesignCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                designCapacity = designRef
            }
            if let maxCapRef = IORegistryEntryCreateCFProperty(service, "MaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                maxCapacityFromSmart = maxCapRef
            }
            
            if designCapacity > 0 && maxCapacityFromSmart > 0 {
                let health = (Double(maxCapacityFromSmart) / Double(designCapacity)) * 100.0
                
                let healthPrefix = "Pil Sağlığı: "
                let healthValue = String(format: "%%%d ( %d Devir )", Int(health), cycleCount)
                
                let menuFont = NSFont.menuFont(ofSize: 0)
                
                let attrStr = NSMutableAttributedString(string: healthPrefix, attributes: [
                    .font: menuFont,
                    .foregroundColor: NSColor.textColor
                ])
                let valAttrStr = NSAttributedString(string: healthValue, attributes: [
                    .font: menuFont,
                    .foregroundColor: (health >= 80) ? NSColor.systemGreen : NSColor.systemRed
                ])
                attrStr.append(valAttrStr)
                batteryHealthItem.attributedTitle = attrStr
            } else {
                batteryHealthItem.title = "Pil Sağlığı: Hesaplanamıyor"
            }
            
            IOObjectRelease(service)
        }
        
        if let cpuTemp = cpuTempReader.readCPUTemperature() {
            let cpuPrefix = "İşlemci Sıcaklığı: "
            let remaining = max(100.0 - cpuTemp, 0.0)
            let cpuValue = String(format: "%.1f °C", cpuTemp)
            let remainingValue = String(format: " (Throttling'e %.1f °C)", remaining)
            let menuFont = NSFont.menuFont(ofSize: 0)
            
            let attrStr = NSMutableAttributedString(string: cpuPrefix, attributes: [
                .font: menuFont,
                .foregroundColor: NSColor.textColor
            ])
            
            let tempColor: NSColor
            if cpuTemp >= 75.0 {
                tempColor = NSColor.systemRed
            } else if cpuTemp >= 55.0 {
                tempColor = NSColor.systemOrange
            } else {
                tempColor = NSColor.systemBlue
            }
            
            let valAttrStr = NSAttributedString(string: cpuValue, attributes: [
                .font: menuFont,
                .foregroundColor: tempColor
            ])
            attrStr.append(valAttrStr)
            
            let remainingAttrStr = NSAttributedString(string: remainingValue, attributes: [
                .font: menuFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            attrStr.append(remainingAttrStr)
            
            cpuTemperatureItem.attributedTitle = attrStr
        } else {
            cpuTemperatureItem.title = "İşlemci Sıcaklığı: -- °C"
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
            if !isCharging {
                screenOnTime = 0
            }
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
            .foregroundColor: NSColor.textColor
        ])
        let avgValAttrStr = NSAttributedString(string: avgValue, attributes: [
            .font: menuFont,
            .foregroundColor: NSColor.systemCyan
        ])
        avgAttrStr.append(avgValAttrStr)
        averageWattageItem.attributedTitle = avgAttrStr
        
        if !isCharging && isScreenOn {
            if delta > 0 && delta < 10 { // Max 10 sec delta to ignore sleep gaps
                screenOnTime += delta
            }
        }
        
        let screenOnPrefix = "Ekran Süresi: "
        let screenOnValue = formatTimeInterval(screenOnTime)
        
        let screenOnAttrStr = NSMutableAttributedString(string: screenOnPrefix, attributes: [
            .font: menuFont,
            .foregroundColor: NSColor.textColor
        ])
        let screenOnValAttrStr = NSAttributedString(string: screenOnValue, attributes: [
            .font: menuFont,
            .foregroundColor: NSColor.systemGreen
        ])
        screenOnAttrStr.append(screenOnValAttrStr)
        screenOnTimeItem.attributedTitle = screenOnAttrStr
        
        let wattString = String(format: "%.1fW", watts)
        var timeString = ""
        
        if isFullyCharged {
            timeString = "(Dolu)"
        } else if timeRemaining > 0 && timeRemaining < 6000 {
            let hours = timeRemaining / 60
            let minutes = timeRemaining % 60
            if hours > 0 {
                timeString = "(\(hours)s \(minutes)d)"
            } else {
                timeString = "(\(minutes)d)"
            }
        } else {
            timeString = "(...)"
        }
        
        var titleComponents: [String] = []
        if showWattInMenu {
            titleComponents.append(wattString)
        }
        if showPercentageInMenu {
            titleComponents.append(String(format: "%%%d", Int(percentage)))
        }
        if showTimeInMenu {
            titleComponents.append(timeString)
        }
        
        let title = titleComponents.joined(separator: " ")
        
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
            if percentage >= 80.0 && !hasNotifiedEightyPercent {
                sendNotification(title: "Pil %80 Seviyesine Ulaştı 🔋", body: "Pil sağlığını korumak için şarj cihazını çıkarabilirsiniz.")
                hasNotifiedEightyPercent = true
            }
        } else {
            hasNotifiedFullCharge = false
            hasNotifiedEightyPercent = false
            if percentage <= 20.0 && percentage > 0 && !hasNotifiedLowBattery {
                sendNotification(title: "Düşük Pil Uyarısı 🔋", body: "Piliniz %\u{200B}\(Int(percentage)) değerinin altına düştü, lütfen şarja takın.")
                hasNotifiedLowBattery = true
            } else if percentage > 20.0 {
                hasNotifiedLowBattery = false
            }
        }
    }
}

class CPUTemperatureReader {
    private typealias IOHIDEventSystemClient = AnyObject
    private typealias IOHIDServiceClient = AnyObject
    private typealias IOHIDEvent = AnyObject

    private typealias IOHIDEventSystemClientCreate = @convention(c) (_ allocator: CFAllocator?) -> IOHIDEventSystemClient?
    private typealias IOHIDEventSystemClientSetMatching = @convention(c) (_ client: IOHIDEventSystemClient?, _ matches: CFDictionary?) -> Void
    private typealias IOHIDEventSystemClientCopyServices = @convention(c) (_ client: IOHIDEventSystemClient?) -> CFArray?
    private typealias IOHIDServiceClientCopyEvent = @convention(c) (_ client: IOHIDServiceClient?, _ eventType: Int64, _ option: Int32, _ mask: Int64) -> IOHIDEvent?
    private typealias IOHIDEventGetFloatValue = @convention(c) (_ event: IOHIDEvent?, _ field: UInt32) -> Double
    private typealias IOHIDServiceClientCopyProperty = @convention(c) (_ service: IOHIDServiceClient?, _ property: CFString?) -> CFTypeRef?

    private var client: IOHIDEventSystemClient?
    private var eventSystemClientCopyServices: IOHIDEventSystemClientCopyServices?
    private var serviceClientCopyEvent: IOHIDServiceClientCopyEvent?
    private var eventGetFloatValue: IOHIDEventGetFloatValue?
    private var serviceClientCopyProperty: IOHIDServiceClientCopyProperty?

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        
        let clientCreate = dlsym(handle, "IOHIDEventSystemClientCreate").map {
            unsafeBitCast($0, to: IOHIDEventSystemClientCreate.self)
        }
        let clientSetMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching").map {
            unsafeBitCast($0, to: IOHIDEventSystemClientSetMatching.self)
        }
        eventSystemClientCopyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices").map {
            unsafeBitCast($0, to: IOHIDEventSystemClientCopyServices.self)
        }
        serviceClientCopyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent").map {
            unsafeBitCast($0, to: IOHIDServiceClientCopyEvent.self)
        }
        eventGetFloatValue = dlsym(handle, "IOHIDEventGetFloatValue").map {
            unsafeBitCast($0, to: IOHIDEventGetFloatValue.self)
        }
        serviceClientCopyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty").map {
            unsafeBitCast($0, to: IOHIDServiceClientCopyProperty.self)
        }

        if let clientCreate = clientCreate, let clientSetMatching = clientSetMatching {
            client = clientCreate(kCFAllocatorDefault)
            clientSetMatching(client, [
                "PrimaryUsage": 5,
                "PrimaryUsagePage": 65280
            ] as CFDictionary)
        }
    }

    func readCPUTemperature() -> Double? {
        guard let client = client,
              let copyServices = eventSystemClientCopyServices,
              let copyEvent = serviceClientCopyEvent,
              let getFloatValue = eventGetFloatValue,
              let copyProperty = serviceClientCopyProperty else {
            return nil
        }

        guard let services = copyServices(client) as? [IOHIDServiceClient] else {
            return nil
        }

        var tdieTemperatures: [Double] = []

        for service in services {
            if let nameRef = copyProperty(service, "Product" as CFString) {
                let name = nameRef as! String
                if name.contains("tdie") {
                    if let event = copyEvent(service, 15, 0, 0) {
                        let temp = getFloatValue(event, 983040)
                        if temp > 0 && temp < 150 {
                            tdieTemperatures.append(temp)
                        }
                    }
                }
            }
        }

        if tdieTemperatures.isEmpty {
            return nil
        }
        
        return tdieTemperatures.max()
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
