import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppDelegate {
  func makeEnergyDashboardModel() -> EnergyDashboardModel {
    EnergyDashboardModel(
      actions: EnergyDashboardActions(
        activate: { [weak self] usage in self?.activateApplication(usage) },
        reveal: { [weak self] usage in self?.revealApplication(usage) },
        terminate: { [weak self] usage in self?.terminateApplication(usage) },
        exportCSV: { [weak self] in self?.exportEnergyHistory() }
      )
    )
  }

  func handleProcessEnergyMeasurement(_ measurement: ProcessEnergyMeasurement) {
    let now = Date()
    applicationPowerTimeline.add(measurement, at: now)
    guard
      let snapshot = applicationPowerTimeline.snapshot(
        window: TimeInterval(selectedEnergyWindow.rawValue),
        now: now
      )
    else { return }

    latestAllUsages = snapshot.usages
    latestDisplayedUsages = Array(snapshot.usages.prefix(3))
    latestAttributedWatts = snapshot.attributedTotalWatts
    latestCoverage = snapshot.coverage
    renderEnergyMenu(snapshot)
    let instantSnapshot = SmoothedEnergySnapshot(
      usages: measurement.usages,
      attributedTotalWatts: measurement.attributedTotalWatts,
      coverage: measurement.coverage,
      sampleCount: 1
    )
    recordEnergyHistory(instantSnapshot, at: now)
    updateDashboard(snapshot)
    evaluateSmartAlerts(instantSnapshot, at: now)
  }

  func renderEnergyMenu(_ snapshot: SmoothedEnergySnapshot) {
    topAppsTitleItem.title =
      "\(selectedEnergyWindow.title) · Kapsam %\(Int((snapshot.coverage * 100).rounded()))"
    let total = max(snapshot.attributedTotalWatts, 0)
    let menuItems = [topApp1Item, topApp2Item, topApp3Item]

    for index in 0..<3 {
      guard index < latestDisplayedUsages.count else {
        menuItems[index]?.title = "\(index + 1). --"
        menuItems[index]?.isEnabled = false
        continue
      }
      let usage = latestDisplayedUsages[index]
      let percentage = total > 0 ? Int((usage.watts / total * 100).rounded()) : 0
      menuItems[index]?.title =
        "\(index + 1). \(usage.applicationName) (\(formatProcessWatts(usage.watts)) · %\(percentage))"
      menuItems[index]?.isEnabled = true
    }
  }

  func recordEnergyHistory(_ snapshot: SmoothedEnergySnapshot, at date: Date) {
    let point = EnergyHistoryPoint(
      date: date,
      batteryWatts: lastWatts,
      batteryPercentage: lastPercentage,
      isCharging: lastIsCharging,
      attributedApplicationWatts: snapshot.attributedTotalWatts,
      coverage: snapshot.coverage,
      applications: snapshot.usages.prefix(8).map {
        HistoricalApplicationUsage(applicationName: $0.applicationName, watts: $0.watts)
      }
    )
    _ = energyHistoryStore.append(point)
  }

  func updateDashboard(_ snapshot: SmoothedEnergySnapshot) {
    energyDashboardModel.history = energyHistoryStore.points
    energyDashboardModel.currentUsages = snapshot.usages
    energyDashboardModel.currentBatteryWatts = lastWatts
    energyDashboardModel.currentAttributedWatts = snapshot.attributedTotalWatts
    energyDashboardModel.coverage = snapshot.coverage
  }

  func evaluateSmartAlerts(_ snapshot: SmoothedEnergySnapshot, at date: Date) {
    let severity: ThermalSeverity
    switch ProcessInfo.processInfo.thermalState {
    case .serious: severity = .warning
    case .critical: severity = .critical
    default: severity = .normal
    }
    let settings = SmartAlertSettings(
      enabled: smartAlertsEnabled,
      applicationThresholdWatts: applicationAlertThreshold,
      sustainedDuration: 120,
      cooldown: 1800
    )
    let events = smartAlertEvaluator.evaluate(
      at: date,
      usages: snapshot.usages,
      batteryPercentage: lastPercentage,
      isCharging: lastIsCharging,
      batteryTemperature: lastBatteryTemperature,
      lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
      thermalSeverity: severity,
      settings: settings
    )
    for event in events { sendSmartAlert(event) }
  }

  func sendSmartAlert(_ event: SmartAlertEvent) {
    switch event {
    case .application(let name, let watts):
      sendNotification(
        title: "Yüksek Uygulama Tüketimi",
        body: "\(name), en az 2 dakikadır yaklaşık \(formatProcessWatts(watts)) tüketiyor."
      )
    case .rapidBatteryDrain(let rate):
      sendNotification(
        title: "Olağan Dışı Pil Tüketimi",
        body: String(format: "Pil saatte yaklaşık %%%.0f hızla azalıyor.", rate)
      )
    case .highBatteryTemperature(let celsius):
      sendNotification(
        title: "Pil Sıcaklığı Yüksek",
        body: String(format: "Pil sıcaklığı %.1f °C. Ağır uygulamaları kapatmayı düşünün.", celsius)
      )
    case .thermalPressure:
      sendNotification(
        title: "Sistem Isıl Baskı Altında",
        body: "macOS kritik ısıl baskı bildiriyor. Ağır işlemleri azaltın."
      )
    case .suggestLowPowerMode:
      sendNotification(
        title: "Düşük Güç Modu Önerisi",
        body: "Pil %30'un altında. Pil Ayarları'ndan Düşük Güç Modu'nu açabilirsiniz."
      )
    }
  }

  @objc func changeEnergyWindow(_ sender: NSMenuItem) {
    guard let window = EnergyDisplayWindow(rawValue: sender.tag) else { return }
    selectedEnergyWindow = window
    updateEnergyMenuState()
    if let snapshot = applicationPowerTimeline.snapshot(window: TimeInterval(window.rawValue)) {
      latestAllUsages = snapshot.usages
      latestDisplayedUsages = Array(snapshot.usages.prefix(3))
      latestAttributedWatts = snapshot.attributedTotalWatts
      renderEnergyMenu(snapshot)
      updateDashboard(snapshot)
    }
  }

  @objc func toggleSmartAlerts() {
    smartAlertsEnabled.toggle()
    updateEnergyMenuState()
  }

  @objc func changeAlertThreshold(_ sender: NSMenuItem) {
    applicationAlertThreshold = Double(sender.tag)
    updateEnergyMenuState()
  }

  func updateEnergyMenuState() {
    for item in energyWindowItems {
      item.state = item.tag == selectedEnergyWindow.rawValue ? .on : .off
    }
    smartAlertsItem?.state = smartAlertsEnabled ? .on : .off
    smartAlertsItem?.title = smartAlertsEnabled ? "Akıllı Uyarılar Açık" : "Akıllı Uyarılar Kapalı"
    for item in alertThresholdItems {
      item.state = Double(item.tag) == applicationAlertThreshold ? .on : .off
    }
  }

  func resetProcessEnergyMeasurement() {
    applicationPowerTimeline.reset()
    latestDisplayedUsages = []
    latestAllUsages = []
    setTopAppTitles(["1. Ölçüm hazırlanıyor…", "2. --", "3. --"])
    for item in [topApp1Item, topApp2Item, topApp3Item] {
      item?.isEnabled = false
    }
    processEnergyQueue.async { [weak self] in
      self?.processEnergyMonitor.reset()
    }
  }

  @objc func openTopApplication(_ sender: NSMenuItem) {
    guard sender.tag >= 0, sender.tag < latestDisplayedUsages.count else { return }
    energyDashboardModel.selectedApplicationName = latestDisplayedUsages[sender.tag].applicationName
    openEnergyDashboard()
  }

  @objc func openEnergyDashboard() {
    if energyDashboardWindowController == nil {
      energyDashboardWindowController = EnergyDashboardWindowController(model: energyDashboardModel)
    }
    energyDashboardWindowController?.present()
  }

  @objc func exportEnergyHistory() {
    let panel = NSSavePanel()
    panel.title = "Enerji Geçmişini Dışa Aktar"
    panel.nameFieldStringValue = "WattWhat-Enerji-Gecmisi.csv"
    panel.allowedContentTypes = [.commaSeparatedText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try energyHistoryStore.csv().write(to: url, atomically: true, encoding: .utf8)
    } catch {
      let alert = NSAlert(error: error)
      alert.messageText = "CSV dosyası kaydedilemedi"
      alert.runModal()
    }
  }

  func activateApplication(_ usage: ApplicationPowerUsage) {
    runningApplication(for: usage)?.activate(options: [.activateAllWindows])
  }

  func revealApplication(_ usage: ApplicationPowerUsage) {
    guard !usage.bundlePath.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: usage.bundlePath)])
  }

  func terminateApplication(_ usage: ApplicationPowerUsage) {
    let alert = NSAlert()
    alert.messageText = "\(usage.applicationName) kapatılsın mı?"
    alert.informativeText = "Kaydedilmemiş çalışmalar kaybolabilir."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Vazgeç")
    alert.addButton(withTitle: "Kapat")
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    _ = runningApplication(for: usage)?.terminate()
  }

  private func runningApplication(for usage: ApplicationPowerUsage) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { application in
      application.bundleURL?.path == usage.bundlePath
        || application.localizedName == usage.applicationName
    }
  }
}
