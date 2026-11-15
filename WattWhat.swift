import Cocoa
import IOKit.ps
import IOKit
import ServiceManagement
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let appVersion = "2.0.0"
    var statusItem: NSStatusItem!
    var timer: Timer?
    var updateTimer: Timer?
    var loginItem: NSMenuItem!
    var averageWattageItem: NSMenuItem!
    var temperatureItem: NSMenuItem!
    var cpuTemperatureItem: NSMenuItem!
    var topApp1Item: NSMenuItem!
    var topApp2Item: NSMenuItem!
    var topApp3Item: NSMenuItem!
    var topAppsTitleItem: NSMenuItem!
    var smartAlertsItem: NSMenuItem!
    var energyWindowItems: [NSMenuItem] = []
    var alertThresholdItems: [NSMenuItem] = []
    var screenOnTimeItem: NSMenuItem!
    var batteryHealthItem: NSMenuItem!
    
    var showWattItem: NSMenuItem!
    var showPercentageItem: NSMenuItem!
    var showTimeItem: NSMenuItem!
    var showTargetWattItem: NSMenuItem!
    
    let cpuTempReader = CPUTemperatureReader()
    let processEnergyMonitor = ProcessEnergyMonitor()
    let processEnergyQueue = DispatchQueue(label: "com.wattwhat.process-energy", qos: .utility)
    let applicationPowerTimeline = ApplicationPowerTimeline()
    let smartAlertEvaluator = SmartAlertEvaluator()
    lazy var energyHistoryStore = EnergyHistoryStore(
        minimumInterval: 60,
        saveInterval: 300,
        maxPoints: 2_880
    )
    lazy var energyDashboardModel = makeEnergyDashboardModel()
    lazy var powerStudioModel = makePowerStudioModel()
    var chargeControlConfig: ChargeControlConfig = LocalConfigStore.load()
    var lastHelperResponse: HelperResponse?
    let helperIPCQueue = DispatchQueue(label: "com.kuarezma.wattwhat.helper-ipc", qos: .userInitiated)
    var powerSummaryMenuItem: NSMenuItem!
    var powerHelperActionItem: NSMenuItem!
    var chargeModeMenuItem: NSMenuItem!
    var chargeModeSubmenuItems: [NSMenuItem] = []
    var chargeLimitSubmenuItems: [NSMenuItem] = []
    var magSafeLEDSubmenuItems: [NSMenuItem] = []
    var topUpMenuItem: NSMenuItem!
    var energyDashboardWindowController: EnergyDashboardWindowController?
    var latestDisplayedUsages: [ApplicationPowerUsage] = []
    var latestAllUsages: [ApplicationPowerUsage] = []
    var latestAttributedWatts = 0.0
    var latestCoverage = 0.0
    var lastBatteryTemperature: Double?
    var lastCPUTemperature: Double?
    var isMenuOpen = false
    var lastThermalSampleDate: Date = .distantPast
    var lastStatusBarTitleString: String = ""
    var lastStatusBarColorState: Int = -1
    var cachedCycleCount: Int = 0
    var cachedDesignCapacity: Int = 0
    var cachedMaxCapacitymAh: Int = 0
    var cachedHealthPercentage: Double = 0.0
    var lastPluggedIn: Bool = false
    
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
    var showTargetWattInMenu: Bool {
        get { UserDefaults.standard.object(forKey: "showTargetWattInMenu") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showTargetWattInMenu") }
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
    
    var cachedSystemProfilerBatteryHealth: Double?

    var lastWatts: Double = 0.0
    var lastPercentage: Double = 0.0
    var lastTimeString: String = "(...)"
    var lastIsCharging: Bool = false

    var selectedEnergyWindow: EnergyDisplayWindow {
        get { EnergyDisplayWindow(rawValue: UserDefaults.standard.integer(forKey: "energyDisplayWindow")) ?? .instant }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "energyDisplayWindow") }
    }
    var smartAlertsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "smartAlertsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "smartAlertsEnabled") }
    }
    var applicationAlertThreshold: Double {
        get { UserDefaults.standard.object(forKey: "applicationAlertThreshold") as? Double ?? 5.0 }
        set { UserDefaults.standard.set(newValue, forKey: "applicationAlertThreshold") }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kuarezma.wattwhat"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            NSApp.terminate(nil)
            return
        }

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        let menu = NSMenu()
        menu.delegate = self
        
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

        setupChargeControlMenuItems(into: menu)

        topAppsTitleItem = NSMenuItem(title: "Son 3 Sn. Uygulama Enerjisi", action: nil, keyEquivalent: "")
        topAppsTitleItem.isEnabled = false
        menu.addItem(topAppsTitleItem)
        
        topApp1Item = NSMenuItem(title: "1. Ölçüm hazırlanıyor…", action: #selector(openTopApplication), keyEquivalent: "")
        topApp1Item.target = self
        topApp1Item.tag = 0
        topApp1Item.isEnabled = false
        menu.addItem(topApp1Item)
        
        topApp2Item = NSMenuItem(title: "2. --", action: #selector(openTopApplication), keyEquivalent: "")
        topApp2Item.target = self
        topApp2Item.tag = 1
        topApp2Item.isEnabled = false
        menu.addItem(topApp2Item)
        
        topApp3Item = NSMenuItem(title: "3. --", action: #selector(openTopApplication), keyEquivalent: "")
        topApp3Item.target = self
        topApp3Item.tag = 2
        topApp3Item.isEnabled = false
        menu.addItem(topApp3Item)

        let measurementMenu = NSMenu()
        for window in EnergyDisplayWindow.allCases {
            let item = NSMenuItem(title: window.title, action: #selector(changeEnergyWindow), keyEquivalent: "")
            item.target = self
            item.tag = window.rawValue
            measurementMenu.addItem(item)
            energyWindowItems.append(item)
        }
        let measurementItem = NSMenuItem(title: "Ölçüm Aralığı", action: nil, keyEquivalent: "")
        measurementItem.submenu = measurementMenu
        menu.addItem(measurementItem)

        let historyItem = NSMenuItem(title: "Enerji Geçmişini Aç", action: #selector(openEnergyDashboard), keyEquivalent: "e")
        historyItem.target = self
        menu.addItem(historyItem)
        let exportItem = NSMenuItem(title: "CSV Dışa Aktar", action: #selector(exportEnergyHistory), keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)

        let alertsMenu = NSMenu()
        smartAlertsItem = NSMenuItem(title: "Akıllı Uyarılar Açık", action: #selector(toggleSmartAlerts), keyEquivalent: "")
        smartAlertsItem.target = self
        alertsMenu.addItem(smartAlertsItem)
        alertsMenu.addItem(NSMenuItem.separator())
        for threshold in [3.0, 5.0, 10.0] {
            let item = NSMenuItem(title: "Uygulama Eşiği: \(Int(threshold)) W", action: #selector(changeAlertThreshold), keyEquivalent: "")
            item.target = self
            item.tag = Int(threshold)
            alertsMenu.addItem(item)
            alertThresholdItems.append(item)
        }
        let alertsItem = NSMenuItem(title: "Akıllı Uyarılar", action: nil, keyEquivalent: "")
        alertsItem.submenu = alertsMenu
        menu.addItem(alertsItem)
        
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
        showTargetWattItem = NSMenuItem(title: "Hedef Watt'ı Göster", action: #selector(toggleShowTargetInMenu), keyEquivalent: "")
        appearanceMenu.addItem(showWattItem)
        appearanceMenu.addItem(showPercentageItem)
        appearanceMenu.addItem(showTimeItem)
        appearanceMenu.addItem(showTargetWattItem)
        
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
        updateEnergyMenuState()
        updatePowerControlMenuState()
        updateLoginItemState()
        updateBatteryStatus()
        refreshPowerControlStateBackground(forceProbe: true)
        
        checkForUpdatesAndHealth()
        
        updateTimer = Timer.scheduledTimer(timeInterval: 43200.0, target: self, selector: #selector(checkForUpdatesAndHealth), userInfo: nil, repeats: true)
        
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
    
    @objc func checkForUpdates() {
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
        alert.informativeText = "WattWhat'ın yeni sürümü (\(newVersion)) çıktı. Şimdi güncellemek ister misiniz?\n\nGüncelle işlemi arka planda sessizce indirilecek ve uygulama yeniden başlatılacaktır."
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
    
    @objc func checkForUpdatesAndHealth() {
        checkForUpdates()
        updateSystemProfilerBatteryHealth()
    }
    
    @objc func updateSystemProfilerBatteryHealth() {
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            task.launchPath = "/usr/sbin/system_profiler"
            task.arguments = ["SPPowerDataType"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let regex = try NSRegularExpression(pattern: "Maximum Capacity:\\s*[%]?(\\d+)[%]?", options: .caseInsensitive)
                    if let match = regex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
                        if let range = Range(match.range(at: 1), in: output), let percentage = Double(String(output[range])) {
                            DispatchQueue.main.async {
                                self.cachedSystemProfilerBatteryHealth = percentage
                                self.updateBatteryStatus()
                            }
                        }
                    }
                }
            } catch {
                print("Failed to get system_profiler battery health")
            }
        }
    }
    
    @objc func screenDidSleep() {
        isScreenOn = false
        resetProcessEnergyMeasurement()
    }
    @objc func screenDidWake() { 
        isScreenOn = true
        lastUpdateDate = Date()
        resetProcessEnergyMeasurement()
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
        refreshStatusBarTitle()
    }

    @objc func toggleShowPercentage() {
        showPercentageInMenu.toggle()
        updateAppearanceMenuState()
        refreshStatusBarTitle()
    }

    @objc func toggleShowTime() {
        showTimeInMenu.toggle()
        updateAppearanceMenuState()
        refreshStatusBarTitle()
    }
    
    func updateAppearanceMenuState() {
        showWattItem.state = showWattInMenu ? .on : .off
        showPercentageItem.state = showPercentageInMenu ? .on : .off
        showTimeItem.state = showTimeInMenu ? .on : .off
        showTargetWattItem?.state = showTargetWattInMenu ? .on : .off
    }
    
    @objc func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func closeAllApps() {
        let alert = NSAlert()
        alert.messageText = "Tüm uygulamalar kapatılsın mı?"
        alert.informativeText = "Kaydedilmemiş çalışmalar kaybolabilir. Tek bir uygulamayı kapatmak için Enerji Geçmişi ekranını kullanmanız önerilir."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Vazgeç")
        alert.addButton(withTitle: "Tümünü Kapat")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let apps = NSWorkspace.shared.runningApplications
        let currentApp = NSRunningApplication.current
        for app in apps {
            if app.activationPolicy == .regular && app != currentApp && app.bundleIdentifier != "com.apple.Finder" {
                app.terminate()
            }
        }
    }
    
    func updateTopAppsBackground() {
        processEnergyQueue.async { [weak self] in
            guard let self else { return }
            let sample = self.processEnergyMonitor.sample()
            DispatchQueue.main.async {
                self.displayProcessEnergy(sample)
            }
        }
    }

    func displayProcessEnergy(_ sample: ProcessEnergySample) {
        switch sample {
        case .warmingUp:
            latestDisplayedUsages = []
            setTopAppTitles(["1. Ölçüm hazırlanıyor…", "2. --", "3. --"])
            [topApp1Item, topApp2Item, topApp3Item].forEach { $0?.isEnabled = false }
        case .unavailable:
            latestDisplayedUsages = []
            setTopAppTitles(["1. Enerji verisi alınamadı", "2. --", "3. --"])
            [topApp1Item, topApp2Item, topApp3Item].forEach { $0?.isEnabled = false }
        case .available(let measurement):
            handleProcessEnergyMeasurement(measurement)
        }
    }

    func setTopAppTitles(_ titles: [String]) {
        topApp1Item.title = titles[0]
        topApp2Item.title = titles[1]
        topApp3Item.title = titles[2]
    }

    func formatProcessWatts(_ watts: Double) -> String {
        if watts > 0 && watts < 0.01 { return "<0,01 W" }
        return String(format: "%.2f W", locale: Locale(identifier: "tr_TR"), watts)
    }

    func applicationWillTerminate(_ notification: Notification) {
        energyHistoryStore.flush()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        lastThermalSampleDate = .distantPast
        updateBatteryStatus()
        refreshPowerControlStateBackground(forceProbe: true)
        if let snapshot = applicationPowerTimeline.snapshot(window: TimeInterval(selectedEnergyWindow.rawValue)) {
            renderEnergyMenu(snapshot)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    @objc func quitApp() {
        energyHistoryStore.flush()
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
    
    func refreshStatusBarTitle() {
        let wattString: String
        if showTargetWattInMenu && lastPluggedIn {
            switch chargeControlConfig.mode {
            case .automatic:
                wattString = String(format: "%.1fW", lastWatts)
            case .manualWatts:
                let target = lastHelperResponse?.appliedTargetWatts ?? chargeControlConfig.targetWatts
                wattString = String(format: "%.1fW/%dW", lastWatts, target)
            case .passthroughHold:
                wattString = String(format: "%.1fW/0W", lastWatts)
            case .forceDischarge:
                wattString = String(format: "%.1fW(↓%%%d)", lastWatts, chargeControlConfig.dischargeTargetPercent)
            }
        } else {
            wattString = String(format: "%.1fW", lastWatts)
        }
        var titleComponents: [String] = []
        if showWattInMenu {
            titleComponents.append(wattString)
        }
        if showPercentageInMenu {
            titleComponents.append(String(format: "%%%d", Int(lastPercentage)))
        }
        if showTimeInMenu {
            titleComponents.append(lastTimeString)
        }

        let title = titleComponents.joined(separator: " ")
        let colorState: Int
        if lastPluggedIn && chargeControlConfig.mode == .manualWatts {
            colorState = 3 // Manuel Watt Limiti aktif
        } else if lastIsCharging {
            colorState = 2 // Aktif şarj
        } else if lastPluggedIn {
            colorState = 1 // Adaptörde (dolu / koruma modunda)
        } else {
            colorState = 0 // Pilde
        }

        if let button = statusItem.button {
            if title != lastStatusBarTitleString {
                lastStatusBarTitleString = title
                let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                button.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
            }

            if colorState != lastStatusBarColorState {
                lastStatusBarColorState = colorState
                let symbolColor: NSColor
                switch colorState {
                case 3: symbolColor = .systemCyan
                case 2: symbolColor = .systemGreen
                case 1: symbolColor = .systemTeal
                default: symbolColor = .systemYellow
                }
                let config = NSImage.SymbolConfiguration(paletteColors: [symbolColor])
                let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
                symbol?.isTemplate = false
                button.image = symbol
                button.imagePosition = .imageLeft
            }
        }
    }

    private static func signedInt64Value(_ raw: Any?) -> Int64? {
        if let number = raw as? NSNumber {
            return Int64(bitPattern: number.uint64Value)
        }
        if let intVal = raw as? Int {
            return Int64(intVal)
        }
        return nil
    }

    @objc func updateBatteryStatus() {
        let now = Date()
        let delta = now.timeIntervalSince(lastUpdateDate)
        lastUpdateDate = now
        
        var watts: Double = 0.0
        var isPluggedInSmart = false
        var isChargingSmart = false
        let shouldReadThermal = isMenuOpen || now.timeIntervalSince(lastThermalSampleDate) >= 30.0
        if shouldReadThermal {
            lastThermalSampleDate = now
        }

        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }

            let voltageRaw = IORegistryEntryCreateCFProperty(service, "Voltage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            let amperageRaw = IORegistryEntryCreateCFProperty(service, "Amperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            if let voltage = Self.signedInt64Value(voltageRaw),
               let amperage = Self.signedInt64Value(amperageRaw),
               voltage > 0 {
                watts = abs(Double(voltage) * Double(amperage)) / 1_000_000.0
            }

            if let extConn = IORegistryEntryCreateCFProperty(service, "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
                isPluggedInSmart = extConn
            }
            if let chargingProp = IORegistryEntryCreateCFProperty(service, "IsCharging" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
                isChargingSmart = chargingProp
            }

            let telemetryDict = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            if watts < 0.05, let telemetryDict {
                if let sysLoad = Self.signedInt64Value(telemetryDict["SystemLoad"]), sysLoad > 0, sysLoad < 250_000 {
                    watts = Double(sysLoad) / 1_000.0
                } else if let sysPowerIn = Self.signedInt64Value(telemetryDict["SystemPowerIn"]), sysPowerIn > 0, sysPowerIn < 250_000 {
                    watts = Double(sysPowerIn) / 1_000.0
                } else if let battPower = Self.signedInt64Value(telemetryDict["BatteryPower"]), battPower != 0, abs(battPower) < 250_000 {
                    watts = abs(Double(battPower)) / 1_000.0
                }
            }

            let batteryDataDict = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]

            if shouldReadThermal {
                if let tempRef = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int, tempRef > 0 {
                    lastBatteryTemperature = Double(tempRef) / 100.0
                } else {
                    lastBatteryTemperature = cpuTempReader.readBatteryTemperature()
                }
                lastCPUTemperature = cpuTempReader.readCPUTemperature()
            }

            var cycleCount = 0
            var designCapacity = 0
            var maxCapacityFromSmart = 0

            if let cycleRef = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                cycleCount = cycleRef
            }
            if let designRef = IORegistryEntryCreateCFProperty(service, "DesignCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int, designRef > 100 {
                designCapacity = designRef
            } else if let bdDesign = batteryDataDict?["DesignCapacity"] as? Int, bdDesign > 100 {
                designCapacity = bdDesign
            }
            
            if let appleRawRef = IORegistryEntryCreateCFProperty(service, "AppleRawMaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int, appleRawRef > 100 {
                maxCapacityFromSmart = appleRawRef
            } else if let nominalRef = IORegistryEntryCreateCFProperty(service, "NominalChargeCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int, nominalRef > 100 {
                maxCapacityFromSmart = nominalRef
            } else if let bdNominal = batteryDataDict?["NominalChargeCapacity"] as? Int, bdNominal > 100 {
                maxCapacityFromSmart = bdNominal
            } else if let bdFull = batteryDataDict?["FullChargeCapacity"] as? Int, bdFull > 100 {
                maxCapacityFromSmart = bdFull
            } else if let maxCapRef = IORegistryEntryCreateCFProperty(service, "MaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                maxCapacityFromSmart = maxCapRef
            }

            cachedCycleCount = cycleCount
            cachedDesignCapacity = designCapacity
            cachedMaxCapacitymAh = maxCapacityFromSmart
            if designCapacity > 0 && maxCapacityFromSmart > 0 {
                var health = 0.0
                if let sysHealth = cachedSystemProfilerBatteryHealth {
                    health = sysHealth
                } else if maxCapacityFromSmart <= 100 && designCapacity > 1000 {
                    health = Double(maxCapacityFromSmart)
                } else {
                    health = (Double(maxCapacityFromSmart) / Double(designCapacity)) * 100.0
                }
                cachedHealthPercentage = min(health, 100.0)
            }
        }
        
        var isPluggedIn = isPluggedInSmart
        var isCharging = isChargingSmart
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
                isPluggedIn = (state == kIOPSACPowerValue) || isPluggedInSmart
                if let iopsCharging = info[kIOPSIsChargingKey] as? Bool {
                    isCharging = iopsCharging
                }
                isFullyCharged = (info[kIOPSIsChargedKey] as? Bool) ?? false
                
                let currentCapacity = info[kIOPSCurrentCapacityKey] as? Int ?? 0
                let maxCapacity = info[kIOPSMaxCapacityKey] as? Int ?? 100
                if maxCapacity > 0 {
                    percentage = (Double(currentCapacity) / Double(maxCapacity)) * 100.0
                }
                
                if isCharging {
                    timeRemaining = info[kIOPSTimeToFullChargeKey] as? Int ?? 0
                } else if !isPluggedIn {
                    timeRemaining = info[kIOPSTimeToEmptyKey] as? Int ?? 0
                }
            }
        }
        
        if isPluggedIn != wasCharging {
            let prevPlugged = wasCharging
            if !isPluggedIn {
                screenOnTime = 0
            }
            totalWatts = 0.0
            wattSamplesCount = 0
            wasCharging = isPluggedIn
            if !prevPlugged && isPluggedIn {
                let adapterRating = PowerTelemetryReader.read(now: now).adapterRatingWatts
                handlePlugInTransition(
                    wasPluggedIn: prevPlugged,
                    nowPluggedIn: isPluggedIn,
                    adapterRatingWatts: adapterRating
                )
            }
        }
        
        if watts > 0.01 {
            totalWatts += watts
            wattSamplesCount += 1
        }
        let avg = wattSamplesCount > 0 ? (totalWatts / Double(wattSamplesCount)) : watts
        
        if !isPluggedIn && isScreenOn {
            if delta > 0 && delta < 10 { // Max 10 sec delta to ignore sleep gaps
                screenOnTime += delta
            }
        }
        
        var timeString = ""
        if isFullyCharged || (isPluggedIn && !isCharging) {
            timeString = isFullyCharged ? "(Dolu)" : "(Fişte)"
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

        lastWatts = watts
        lastPercentage = percentage
        lastTimeString = timeString
        lastIsCharging = isCharging
        lastPluggedIn = isPluggedIn

        if isMenuOpen {
            updateDetailedMenuItems(avgWatts: avg, isPluggedIn: isPluggedIn, isCharging: isCharging)
        }

        refreshStatusBarTitle()
        updateTopAppsBackground()
        refreshPowerControlStateBackground(forceProbe: false)

        if isPluggedIn {
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

    private func updateDetailedMenuItems(avgWatts: Double, isPluggedIn: Bool, isCharging: Bool) {
        let menuFont = NSFont.menuFont(ofSize: 0)

        if let celsius = lastBatteryTemperature {
            let tempPrefix = "Pil Sıcaklığı: "
            let tempValue = String(format: "%.1f °C", celsius)
            let attrStr = NSMutableAttributedString(string: tempPrefix, attributes: [
                .font: menuFont,
                .foregroundColor: NSColor.textColor
            ])
            attrStr.append(NSAttributedString(string: tempValue, attributes: [
                .font: menuFont,
                .foregroundColor: NSColor.systemOrange
            ]))
            temperatureItem.attributedTitle = attrStr
        } else {
            temperatureItem.title = "Pil Sıcaklığı: -- °C"
        }

        if cachedDesignCapacity > 0 && cachedMaxCapacitymAh > 0 {
            let healthPrefix = "Pil Sağlığı: "
            let healthValue: String
            if cachedMaxCapacitymAh > 100 {
                healthValue = String(format: "%%%.0f (%d mAh Kaldı, %d Devir)", cachedHealthPercentage, cachedMaxCapacitymAh, cachedCycleCount)
            } else {
                healthValue = String(format: "%%%.0f (%d Devir)", cachedHealthPercentage, cachedCycleCount)
            }
            let attrStr = NSMutableAttributedString(string: healthPrefix, attributes: [
                .font: menuFont,
                .foregroundColor: NSColor.textColor
            ])
            attrStr.append(NSAttributedString(string: healthValue, attributes: [
                .font: menuFont,
                .foregroundColor: (cachedHealthPercentage >= 80) ? NSColor.systemGreen : NSColor.systemRed
            ]))
            batteryHealthItem.attributedTitle = attrStr
        } else {
            batteryHealthItem.title = "Pil Sağlığı: Hesaplanamıyor"
        }

        if let cpuTemp = lastCPUTemperature {
            let cpuPrefix = "İşlemci Sıcaklığı: "
            let remaining = max(100.0 - cpuTemp, 0.0)
            let cpuValue = String(format: "%.1f °C", cpuTemp)
            let remainingValue = String(format: " (Throttling'e %.1f °C)", remaining)
            let attrStr = NSMutableAttributedString(string: cpuPrefix, attributes: [
                .font: menuFont,
                .foregroundColor: NSColor.textColor
            ])
            let tempColor: NSColor
            if cpuTemp >= 75.0 {
                tempColor = .systemRed
            } else if cpuTemp >= 55.0 {
                tempColor = .systemOrange
            } else {
                tempColor = .systemBlue
            }
            attrStr.append(NSAttributedString(string: cpuValue, attributes: [
                .font: menuFont,
                .foregroundColor: tempColor
            ]))
            attrStr.append(NSAttributedString(string: remainingValue, attributes: [
                .font: menuFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            cpuTemperatureItem.attributedTitle = attrStr
        } else {
            cpuTemperatureItem.title = "İşlemci Sıcaklığı: -- °C"
        }

        let avgPrefix: String
        if isCharging {
            avgPrefix = "Ortalama Şarj: "
        } else if isPluggedIn {
            avgPrefix = "Ortalama Adaptör: "
        } else {
            avgPrefix = "Ortalama Tüketim: "
        }
        let avgValue = String(format: "%.1f W", avgWatts)
        let avgAttrStr = NSMutableAttributedString(string: avgPrefix, attributes: [
            .font: menuFont,
            .foregroundColor: NSColor.textColor
        ])
        avgAttrStr.append(NSAttributedString(string: avgValue, attributes: [
            .font: menuFont,
            .foregroundColor: NSColor.systemCyan
        ]))
        averageWattageItem.attributedTitle = avgAttrStr

        let screenOnPrefix = "Ekran Süresi: "
        let screenOnValue = formatTimeInterval(screenOnTime)
        let screenOnAttrStr = NSMutableAttributedString(string: screenOnPrefix, attributes: [
            .font: menuFont,
            .foregroundColor: NSColor.textColor
        ])
        screenOnAttrStr.append(NSAttributedString(string: screenOnValue, attributes: [
            .font: menuFont,
            .foregroundColor: NSColor.systemGreen
        ]))
        screenOnTimeItem.attributedTitle = screenOnAttrStr
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
    private var cachedTDieServices: [IOHIDServiceClient]?
    private var cachedBatteryServices: [IOHIDServiceClient]?

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

    private func populateSensorCachesIfNeeded() {
        guard cachedTDieServices == nil || cachedBatteryServices == nil,
              let client = client,
              let copyServices = eventSystemClientCopyServices,
              let copyProperty = serviceClientCopyProperty,
              let services = copyServices(client) as? [IOHIDServiceClient] else {
            return
        }
        var tdie: [IOHIDServiceClient] = []
        var battery: [IOHIDServiceClient] = []
        for service in services {
            if let nameRef = copyProperty(service, "Product" as CFString),
               let name = nameRef as? String {
                let lower = name.lowercased()
                if lower.contains("tdie") {
                    tdie.append(service)
                } else if lower.contains("gas gauge battery") || lower.contains("batt") {
                    battery.append(service)
                }
            }
        }
        cachedTDieServices = tdie
        cachedBatteryServices = battery
    }

    func readCPUTemperature() -> Double? {
        populateSensorCachesIfNeeded()
        guard let services = cachedTDieServices,
              let copyEvent = serviceClientCopyEvent,
              let getFloatValue = eventGetFloatValue else {
            return nil
        }

        var maxTemp: Double?
        for service in services {
            if let event = copyEvent(service, 15, 0, 0) {
                let temp = getFloatValue(event, 983040)
                if temp > 0 && temp < 150 {
                    if let current = maxTemp {
                        if temp > current { maxTemp = temp }
                    } else {
                        maxTemp = temp
                    }
                }
            }
        }
        return maxTemp
    }

    func readBatteryTemperature() -> Double? {
        populateSensorCachesIfNeeded()
        guard let services = cachedBatteryServices,
              let copyEvent = serviceClientCopyEvent,
              let getFloatValue = eventGetFloatValue else {
            return nil
        }

        var sum = 0.0
        var count = 0
        for service in services {
            if let event = copyEvent(service, 15, 0, 0) {
                let temp = getFloatValue(event, 983040)
                if temp > 5 && temp < 100 {
                    sum += temp
                    count += 1
                }
            }
        }
        return count > 0 ? (sum / Double(count)) : nil
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

@main
struct WattWhatApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
