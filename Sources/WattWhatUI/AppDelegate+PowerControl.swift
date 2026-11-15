import AppKit
import Foundation

extension AppDelegate {
  func makePowerStudioModel() -> PowerStudioModel {
    PowerStudioModel(
      initialConfig: chargeControlConfig,
      actions: PowerStudioActions(
        applyConfig: { [weak self] newConfig in
          self?.applyChargeConfig(newConfig)
        },
        setAutomatic: { [weak self] in
          self?.setChargeModeAutomatic()
        },
        setLowPowerMode: { [weak self] enabled in
          self?.applyLowPowerMode(enabled)
        },
        installHelper: { [weak self] in
          self?.installPowerHelperFromUI()
        },
        uninstallHelper: { [weak self] in
          self?.uninstallPowerHelperFromUI()
        },
        refreshNow: { [weak self] in
          self?.refreshPowerControlStateBackground(forceProbe: true)
        }
      )
    )
  }

  func setupChargeControlMenuItems(into menu: NSMenu) {
    let studioItem = NSMenuItem(
      title: "⚡️ Şarj & Güç Stüdyosu…",
      action: #selector(openPowerStudio),
      keyEquivalent: "p"
    )
    studioItem.target = self
    menu.addItem(studioItem)

    powerSummaryMenuItem = NSMenuItem(
      title: "Güç Akışı: Ölçülüyor…",
      action: #selector(openPowerStudio),
      keyEquivalent: ""
    )
    powerSummaryMenuItem.target = self
    menu.addItem(powerSummaryMenuItem)

    powerHelperActionItem = NSMenuItem(
      title: "Yetkili Güç Motorunu Etkinleştir…",
      action: #selector(installPowerHelperFromUI),
      keyEquivalent: ""
    )
    powerHelperActionItem.target = self
    menu.addItem(powerHelperActionItem)

    // Şarj Gücü Modu alt menüsü
    let modeMenu = NSMenu()
    let autoItem = NSMenuItem(
      title: "🤖 Otomatik (macOS Yönetimi)",
      action: #selector(selectAutoChargeMode),
      keyEquivalent: ""
    )
    autoItem.target = self
    autoItem.tag = -1
    modeMenu.addItem(autoItem)
    chargeModeSubmenuItems.append(autoItem)

    modeMenu.addItem(NSMenuItem.separator())

    let presets: [(Int, String)] = [
      (5, "🌿 5 W — Ultra Yavaş / Sıfır Isı"),
      (10, "❄️ 10 W — Serin Şarj"),
      (15, "⚖️ 15 W — Dengeli Şarj"),
      (20, "⚡️ 20 W — Standart Şarj"),
      (30, "🚀 30 W — Hızlı Şarj"),
      (45, "🔥 45 W — Yüksek Güç"),
      (67, "⚡️ 67 W — Maksimum Hızlı"),
    ]
    for (watt, label) in presets {
      let item = NSMenuItem(
        title: label,
        action: #selector(selectPresetWattCharge),
        keyEquivalent: ""
      )
      item.target = self
      item.tag = watt
      modeMenu.addItem(item)
      chargeModeSubmenuItems.append(item)
    }

    let customWattItem = NSMenuItem(
      title: "🎛️ Özel Watt Gir (5–140 W)…",
      action: #selector(promptCustomWattInput),
      keyEquivalent: ""
    )
    customWattItem.target = self
    customWattItem.tag = -99
    modeMenu.addItem(customWattItem)
    chargeModeSubmenuItems.append(customWattItem)

    modeMenu.addItem(NSMenuItem.separator())

    let passItem = NSMenuItem(
      title: "🛡 Adaptörde Beklet (Şarjı Durdur - 0W)",
      action: #selector(selectPassthroughMode),
      keyEquivalent: ""
    )
    passItem.target = self
    passItem.tag = -2
    modeMenu.addItem(passItem)
    chargeModeSubmenuItems.append(passItem)

    let dischargeItem = NSMenuItem(
      title: "⛵️ Fişteyken Pilden Kullan (Deşarj)",
      action: #selector(selectDischargeMode),
      keyEquivalent: ""
    )
    dischargeItem.target = self
    dischargeItem.tag = -3
    modeMenu.addItem(dischargeItem)
    chargeModeSubmenuItems.append(dischargeItem)

    chargeModeMenuItem = NSMenuItem(title: "Şarj Gücü Kontrolü", action: nil, keyEquivalent: "")
    chargeModeMenuItem.submenu = modeMenu
    menu.addItem(chargeModeMenuItem)

    // Pil Şarj Tavanı alt menüsü
    let limitMenu = NSMenu()
    for limit in [60, 70, 80, 90, 100] {
      let title = limit == 100 ? "%100 (Limitsiz)" : "%\(limit) Tavan"
      let item = NSMenuItem(
        title: title,
        action: #selector(selectChargeLimitPercent),
        keyEquivalent: ""
      )
      item.target = self
      item.tag = limit
      limitMenu.addItem(item)
      chargeLimitSubmenuItems.append(item)
    }
    limitMenu.addItem(NSMenuItem.separator())
    topUpMenuItem = NSMenuItem(
      title: "🚀 Bugünlük %100 Doldur (Top-Up)",
      action: #selector(toggleTopUp100),
      keyEquivalent: ""
    )
    topUpMenuItem.target = self
    limitMenu.addItem(topUpMenuItem)

    let limitMenuItem = NSMenuItem(title: "Pil Şarj Limiti", action: nil, keyEquivalent: "")
    limitMenuItem.submenu = limitMenu
    menu.addItem(limitMenuItem)

    // MagSafe LED alt menüsü
    let ledMenu = NSMenu()
    for (idx, mode) in MagSafeLEDMode.allCases.enumerated() {
      let item = NSMenuItem(
        title: mode.title,
        action: #selector(selectMagSafeLED),
        keyEquivalent: ""
      )
      item.target = self
      item.tag = idx
      ledMenu.addItem(item)
      magSafeLEDSubmenuItems.append(item)
    }
    let ledMenuItem = NSMenuItem(title: "MagSafe LED", action: nil, keyEquivalent: "")
    ledMenuItem.submenu = ledMenu
    menu.addItem(ledMenuItem)

    menu.addItem(NSMenuItem.separator())
  }

  @objc func openPowerStudio() {
    ensureStudioWindowController()
    if let snapshot = applicationPowerTimeline.snapshot(
      window: TimeInterval(selectedEnergyWindow.rawValue))
    {
      updateDashboard(snapshot)
    }
    refreshPowerControlStateBackground(forceProbe: true)
    energyDashboardWindowController?.present(tab: .powerStudio)
  }

  func ensureStudioWindowController() {
    if energyDashboardWindowController == nil {
      energyDashboardWindowController = EnergyDashboardWindowController(
        model: energyDashboardModel,
        powerStudioModel: powerStudioModel
      )
    }
  }

  @objc func toggleShowTargetInMenu() {
    showTargetWattInMenu.toggle()
    updateAppearanceMenuState()
    refreshStatusBarTitle()
  }

  @objc func selectAutoChargeMode() {
    setChargeModeAutomatic()
  }

  @objc func selectPresetWattCharge(_ sender: NSMenuItem) {
    var updated = chargeControlConfig
    updated.mode = .manualWatts
    updated.targetWatts = sender.tag
    applyChargeConfigWithInstallPromptIfNeeded(updated)
  }

  @objc func promptCustomWattInput() {
    let alert = NSAlert()
    alert.messageText = "Özel Şarj Watt Değeri Girin"
    alert.informativeText =
      "MacBook'unuzun hedef şarj gücünü 5 W ile 140 W arasında belirleyin. Kapsam: \(chargeControlConfig.targetScope.title)."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Uygula")
    alert.addButton(withTitle: "Vazgeç")

    let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    inputField.stringValue = "\(chargeControlConfig.targetWatts)"
    inputField.placeholderString = "Örn: 18"
    alert.accessoryView = inputField
    NSApp.activate(ignoringOtherApps: true)
    alert.window.initialFirstResponder = inputField

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let val = Int(inputField.stringValue.trimmingCharacters(in: .whitespaces)),
      (5...140).contains(val)
    else {
      let errAlert = NSAlert()
      errAlert.messageText = "Geçersiz Değer"
      errAlert.informativeText = "Lütfen 5 ile 140 arasında bir tam sayı girin."
      errAlert.runModal()
      return
    }
    var updated = chargeControlConfig
    updated.mode = .manualWatts
    updated.targetWatts = val
    applyChargeConfigWithInstallPromptIfNeeded(updated)
  }

  @objc func selectPassthroughMode() {
    var updated = chargeControlConfig
    updated.mode = .passthroughHold
    applyChargeConfigWithInstallPromptIfNeeded(updated)
  }

  @objc func selectDischargeMode() {
    var updated = chargeControlConfig
    updated.mode = .forceDischarge
    applyChargeConfigWithInstallPromptIfNeeded(updated)
  }

  @objc func selectChargeLimitPercent(_ sender: NSMenuItem) {
    var updated = chargeControlConfig
    updated.maxChargeLimitPercent = sender.tag
    updated.topUpTo100Active = false
    if updated.mode == .automatic && sender.tag < 100 {
      updated.mode = .manualWatts
    }
    applyChargeConfigWithInstallPromptIfNeeded(updated)
  }

  @objc func toggleTopUp100() {
    var updated = chargeControlConfig
    updated.topUpTo100Active.toggle()
    if updated.topUpTo100Active {
      updated.mode = .manualWatts
    }
    applyChargeConfigWithInstallPromptIfNeeded(updated)
  }

  @objc func selectMagSafeLED(_ sender: NSMenuItem) {
    guard sender.tag >= 0, sender.tag < MagSafeLEDMode.allCases.count else { return }
    var updated = chargeControlConfig
    updated.ledMode = MagSafeLEDMode.allCases[sender.tag]
    applyChargeConfigWithInstallPromptIfNeeded(updated)
  }

  func applyChargeConfigWithInstallPromptIfNeeded(_ config: ChargeControlConfig) {
    if !HelperIPCClient.isSocketReachable {
      let alert = NSAlert()
      alert.messageText = "Yetkili Güç Motoru Kurulsun mu?"
      alert.informativeText =
        "Şarj Watt gücünü, tavanı ve MagSafe LED'i donanım seviyesinde kontrol etmek için WattWhat Yetkili Güç Motoru'nun bir kez yönetici izniyle (Touch ID / Şifre) kurulması gerekir."
      alert.alertStyle = .informational
      alert.addButton(withTitle: "Kur ve Uygula ⚡️")
      alert.addButton(withTitle: "Yalnız Tercihi Kaydet")
      NSApp.activate(ignoringOtherApps: true)
      if alert.runModal() == .alertFirstButtonReturn {
        chargeControlConfig = config.clamped()
        LocalConfigStore.save(chargeControlConfig)
        powerStudioModel.config = chargeControlConfig
        runHelperInstallation(thenApply: chargeControlConfig)
        return
      }
    }
    applyChargeConfig(config)
  }

  func applyChargeConfig(_ config: ChargeControlConfig) {
    let clamped = config.clamped()
    chargeControlConfig = clamped
    LocalConfigStore.save(clamped)
    powerStudioModel.config = clamped
    powerStudioModel.isApplying = true
    updatePowerControlMenuState()
    refreshStatusBarTitle()

    helperIPCQueue.async { [weak self] in
      let result = HelperIPCClient.send(HelperRequest(command: .applyConfig, config: clamped))
      let fallbackTelemetry = PowerTelemetryReader.read()
      DispatchQueue.main.async {
        guard let self else { return }
        self.powerStudioModel.isApplying = false
        switch result {
        case .success(let response):
          self.syncPowerControlUI(with: response)
          self.powerStudioModel.statusFeedbackMessage = nil
        case .failure(let error):
          let offline = HelperResponse.offline(
            config: clamped,
            telemetry: fallbackTelemetry,
            diagnostics: AppleSMCClient.probeReadableChargerKeys(),
            error: error.localizedDescription
          )
          self.syncPowerControlUI(with: offline)
          self.powerStudioModel.statusFeedbackMessage =
            "Ayar kaydedildi; donanıma uygulanması için 'Yetkili Güç Motorunu Etkinleştir ⚡️' butonuna basın."
        }
      }
    }
  }

  func setChargeModeAutomatic() {
    var updated = chargeControlConfig
    updated.mode = .automatic
    updated.topUpTo100Active = false
    chargeControlConfig = updated
    LocalConfigStore.save(updated)
    powerStudioModel.config = updated
    updatePowerControlMenuState()
    refreshStatusBarTitle()

    helperIPCQueue.async { [weak self] in
      let result = HelperIPCClient.send(HelperRequest(command: .setAutomatic))
      let fallbackTelemetry = PowerTelemetryReader.read()
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success(let response):
          self.syncPowerControlUI(with: response)
          self.powerStudioModel.statusFeedbackMessage = nil
        case .failure:
          let offline = HelperResponse.offline(
            config: updated,
            telemetry: fallbackTelemetry,
            diagnostics: AppleSMCClient.probeReadableChargerKeys()
          )
          self.syncPowerControlUI(with: offline)
        }
      }
    }
  }

  func applyLowPowerMode(_ enabled: Bool) {
    var updated = chargeControlConfig
    updated.lowPowerModeEnabled = enabled
    chargeControlConfig = updated
    LocalConfigStore.save(updated)
    powerStudioModel.config = updated

    helperIPCQueue.async { [weak self] in
      let result = HelperIPCClient.send(
        HelperRequest(command: .setLowPowerMode, lowPowerMode: enabled))
      DispatchQueue.main.async {
        guard let self else { return }
        if case .success(let response) = result {
          self.syncPowerControlUI(with: response)
        } else {
          self.powerStudioModel.statusFeedbackMessage =
            "Düşük Güç Modu değişimi için Yetkili Güç Motoru aktif olmalıdır."
        }
      }
    }
  }

  @objc func installPowerHelperFromUI() {
    runHelperInstallation(thenApply: nil)
  }

  func runHelperInstallation(thenApply pendingConfig: ChargeControlConfig?) {
    powerStudioModel.isApplying = true
    powerStudioModel.statusFeedbackMessage = "Yönetici izni bekleniyor…"
    helperIPCQueue.async { [weak self] in
      let res = HelperInstaller.installWithAdminPrompt()
      DispatchQueue.main.async {
        guard let self else { return }
        self.powerStudioModel.isApplying = false
        switch res {
        case .success:
          self.powerStudioModel.statusFeedbackMessage = "Yetkili Güç Motoru etkinleştirildi."
          if let pending = pendingConfig {
            self.applyChargeConfig(pending)
          } else {
            self.applyChargeConfig(self.chargeControlConfig)
          }
        case .failure(let error):
          self.powerStudioModel.statusFeedbackMessage = "Kurulum iptal/hata: \(error.localizedDescription)"
          self.refreshPowerControlStateBackground(forceProbe: true)
        }
      }
    }
  }

  @objc func uninstallPowerHelperFromUI() {
    let alert = NSAlert()
    alert.messageText = "Yetkili Güç Motoru Kaldırılsın mı?"
    alert.informativeText =
      "Tüm SMC şarj değerleri macOS fabrika ayarlarına döndürülecek ve arka plan LaunchDaemon servisi kaldırılacaktır."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Vazgeç")
    alert.addButton(withTitle: "Kaldır")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertSecondButtonReturn else { return }

    helperIPCQueue.async { [weak self] in
      let res = HelperInstaller.uninstallWithAdminPrompt()
      DispatchQueue.main.async {
        guard let self else { return }
        switch res {
        case .success:
          self.chargeControlConfig.mode = .automatic
          LocalConfigStore.save(self.chargeControlConfig)
          self.powerStudioModel.statusFeedbackMessage =
            "Servis kaldırıldı ve orijinal şarj ayarları geri yüklendi."
        case .failure(let error):
          self.powerStudioModel.statusFeedbackMessage = "Kaldırma hatası: \(error.localizedDescription)"
        }
        self.refreshPowerControlStateBackground(forceProbe: true)
      }
    }
  }

  func refreshPowerControlStateBackground(forceProbe: Bool = false) {
    let isStudioVisible = energyDashboardWindowController?.window?.isVisible == true
    guard forceProbe || isMenuOpen || isStudioVisible || HelperIPCClient.isSocketReachable else {
      let telemetry = PowerTelemetryReader.read()
      powerStudioModel.telemetry = telemetry
      powerStudioModel.isHelperInstalled = HelperIPCClient.isHelperInstalled
      powerStudioModel.isHelperRunning = false
      powerStudioModel.activeRegulationMethod = .helperOffline
      updatePowerSummaryMenu(telemetry: telemetry)
      updatePowerControlMenuState()
      return
    }

    helperIPCQueue.async { [weak self] in
      let cmd: HelperCommand = (forceProbe || isStudioVisible) ? .probeHardware : .status
      let result = HelperIPCClient.send(HelperRequest(command: cmd), timeoutSeconds: 1.5)
      let fallbackTelemetry = PowerTelemetryReader.read()
      let fallbackDiags =
        (forceProbe || isStudioVisible) ? AppleSMCClient.probeReadableChargerKeys() : []
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success(let response):
          self.syncPowerControlUI(with: response)
        case .failure:
          let offline = HelperResponse.offline(
            config: self.chargeControlConfig,
            telemetry: fallbackTelemetry,
            diagnostics: fallbackDiags
          )
          self.syncPowerControlUI(with: offline)
        }
      }
    }
  }

  func syncPowerControlUI(with response: HelperResponse) {
    lastHelperResponse = response
    if response.isHelperRunning {
      chargeControlConfig = response.config
      LocalConfigStore.save(response.config)
      powerStudioModel.config = response.config
    }
    powerStudioModel.telemetry = response.telemetry
    powerStudioModel.isHelperInstalled = HelperIPCClient.isHelperInstalled
    powerStudioModel.isHelperRunning = response.isHelperRunning
    powerStudioModel.activeRegulationMethod = response.activeRegulationMethod
    powerStudioModel.effectiveReason = response.effectiveReason
    powerStudioModel.appliedTargetWatts = response.appliedTargetWatts
    powerStudioModel.currentDutyCycleRatio = response.currentDutyCycleRatio
    if !response.smcDiagnostics.isEmpty {
      powerStudioModel.smcDiagnostics = response.smcDiagnostics
    }
    updatePowerSummaryMenu(telemetry: response.telemetry)
    updatePowerControlMenuState()
    refreshStatusBarTitle()
  }

  func handlePlugInTransition(wasPluggedIn: Bool, nowPluggedIn: Bool, adapterRatingWatts: Int) {
    guard !wasPluggedIn && nowPluggedIn else { return }
    let nextConfig = ChargePolicyEvaluator.configForPlugIn(
      current: chargeControlConfig,
      adapterRatingWatts: adapterRatingWatts
    )
    if nextConfig != chargeControlConfig {
      applyChargeConfig(nextConfig)
    }
  }

  private func updatePowerSummaryMenu(telemetry: LivePowerTelemetry) {
    guard let item = powerSummaryMenuItem else { return }
    let menuFont = NSFont.menuFont(ofSize: 0)
    let text: String
    if telemetry.isPluggedIn {
      let inW = telemetry.systemInputWatts > 0 ? telemetry.systemInputWatts : Double(telemetry.adapterRatingWatts)
      text = String(
        format: "Adaptör: %.1fW  ·  Sistem: %.1fW  ·  Pil: %+.1fW",
        inW,
        telemetry.systemLoadWatts,
        telemetry.signedBatteryWatts
      )
    } else {
      text = String(format: "Pilde  ·  Tüketim: %.1fW  ·  %%%d", telemetry.batteryChargeWatts, Int(telemetry.batteryPercent))
    }
    item.attributedTitle = NSAttributedString(
      string: text,
      attributes: [.font: menuFont, .foregroundColor: NSColor.secondaryLabelColor]
    )
  }

  func updatePowerControlMenuState() {
    let running = lastHelperResponse?.isHelperRunning ?? false
    powerHelperActionItem?.isHidden = running
    powerHelperActionItem?.title = "⚡️ Yetkili Güç Motorunu Etkinleştir…"

    switch chargeControlConfig.mode {
    case .automatic:
      chargeModeMenuItem?.title = "Şarj Gücü: Otomatik (macOS)"
    case .manualWatts:
      chargeModeMenuItem?.title = "Şarj Gücü: \(chargeControlConfig.targetWatts) W Manuel"
    case .passthroughHold:
      chargeModeMenuItem?.title = "Şarj Gücü: 0 W Beklet (Passthrough)"
    case .forceDischarge:
      chargeModeMenuItem?.title = "Şarj Gücü: Deşarj (%\(chargeControlConfig.dischargeTargetPercent))"
    }

    for item in chargeModeSubmenuItems {
      switch item.tag {
      case -1:
        item.state = (chargeControlConfig.mode == .automatic) ? .on : .off
      case -2:
        item.state = (chargeControlConfig.mode == .passthroughHold) ? .on : .off
      case -3:
        item.state = (chargeControlConfig.mode == .forceDischarge) ? .on : .off
      case -99:
        let isCustomPreset =
          chargeControlConfig.mode == .manualWatts
          && ![5, 10, 15, 20, 30, 45, 67].contains(chargeControlConfig.targetWatts)
        item.state = isCustomPreset ? .on : .off
      default:
        item.state =
          (chargeControlConfig.mode == .manualWatts && chargeControlConfig.targetWatts == item.tag)
          ? .on : .off
      }
    }

    for item in chargeLimitSubmenuItems {
      item.state = (chargeControlConfig.maxChargeLimitPercent == item.tag) ? .on : .off
    }

    topUpMenuItem?.state = chargeControlConfig.topUpTo100Active ? .on : .off

    for item in magSafeLEDSubmenuItems {
      if item.tag >= 0, item.tag < MagSafeLEDMode.allCases.count {
        item.state = (chargeControlConfig.ledMode == MagSafeLEDMode.allCases[item.tag]) ? .on : .off
      }
    }
  }
}
