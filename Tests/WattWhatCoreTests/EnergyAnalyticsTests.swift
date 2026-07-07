import Foundation
import Testing

@testable import WattWhatCore

@Test("Zaman penceresi uygulama gücünü süre ağırlıklı ortalar")
func timelineCalculatesWeightedAverage() {
  let timeline = ApplicationPowerTimeline()
  let now = Date(timeIntervalSince1970: 1_000)
  timeline.add(measurement(watts: 2, interval: 2), at: now.addingTimeInterval(-2))
  timeline.add(measurement(watts: 4, interval: 4), at: now)

  let snapshot = timeline.snapshot(window: 30, now: now)

  #expect(snapshot?.sampleCount == 2)
  #expect(abs((snapshot?.usages[0].watts ?? 0) - (20.0 / 6.0)) < 0.0001)
  #expect(snapshot?.coverage == 0.8)
}

@Test("Geçmiş deposu kısa aralıklı kayıtları yinelenmez ve CSV üretir")
func historyStoreThrottlesAndExports() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let fileURL = directory.appendingPathComponent("history.json")
  let store = EnergyHistoryStore(fileURL: fileURL, retention: 3600, minimumInterval: 30)
  let start = Date(timeIntervalSince1970: 2_000)

  #expect(store.append(historyPoint(at: start)))
  #expect(!store.append(historyPoint(at: start.addingTimeInterval(10))))
  #expect(store.append(historyPoint(at: start.addingTimeInterval(31))))
  #expect(store.points.count == 2)
  #expect(store.csv().contains("Ders:2.000W"))
  #expect(EnergyHistoryStore(fileURL: fileURL).points.count == 2)

  try? FileManager.default.removeItem(at: directory)
}

@Test("Hızlı pil düşüşü, yüksek sıcaklık ve kritik ısıl baskı uyarılır")
func systemHealthAlertsAreDetected() {
  let evaluator = SmartAlertEvaluator()
  let settings = SmartAlertSettings()
  let start = Date(timeIntervalSince1970: 5_000)
  _ = evaluator.evaluate(
    at: start, usages: [], batteryPercentage: 80, isCharging: false,
    batteryTemperature: 30, lowPowerModeEnabled: true, thermalSeverity: .normal,
    settings: settings
  )
  let events = evaluator.evaluate(
    at: start.addingTimeInterval(301), usages: [], batteryPercentage: 78,
    isCharging: false, batteryTemperature: 46, lowPowerModeEnabled: true,
    thermalSeverity: .critical, settings: settings
  )

  #expect(events.contains { if case .rapidBatteryDrain = $0 { true } else { false } })
  #expect(events.contains(.highBatteryTemperature(celsius: 46)))
  #expect(events.contains(.thermalPressure))
}

@Test("Uzun süre eşik üstünde kalan uygulama için tek uyarı üretilir")
func sustainedApplicationAlertUsesCooldown() {
  let evaluator = SmartAlertEvaluator()
  let settings = SmartAlertSettings(
    enabled: true,
    applicationThresholdWatts: 5,
    sustainedDuration: 120,
    cooldown: 1_800
  )
  let start = Date(timeIntervalSince1970: 3_000)
  let usage = appUsage(watts: 6)

  #expect(
    evaluator.evaluate(
      at: start, usages: [usage], batteryPercentage: 80, isCharging: false,
      batteryTemperature: nil, lowPowerModeEnabled: true, thermalSeverity: .normal,
      settings: settings
    ).isEmpty)
  let events = evaluator.evaluate(
    at: start.addingTimeInterval(121), usages: [usage], batteryPercentage: 79,
    isCharging: false, batteryTemperature: nil, lowPowerModeEnabled: true,
    thermalSeverity: .normal, settings: settings
  )
  #expect(events == [.application(name: "Ders", watts: 6)])
  #expect(
    evaluator.evaluate(
      at: start.addingTimeInterval(130), usages: [usage], batteryPercentage: 79,
      isCharging: false, batteryTemperature: nil, lowPowerModeEnabled: true,
      thermalSeverity: .normal, settings: settings
    ).isEmpty)
}

@Test("Düşük pilde Düşük Güç Modu yalnızca bir kez önerilir")
func lowPowerModeSuggestionIsNotRepeated() {
  let evaluator = SmartAlertEvaluator()
  let date = Date(timeIntervalSince1970: 4_000)
  let settings = SmartAlertSettings()
  let first = evaluator.evaluate(
    at: date, usages: [], batteryPercentage: 25, isCharging: false,
    batteryTemperature: nil, lowPowerModeEnabled: false, thermalSeverity: .normal,
    settings: settings
  )
  let second = evaluator.evaluate(
    at: date.addingTimeInterval(3), usages: [], batteryPercentage: 24,
    isCharging: false, batteryTemperature: nil, lowPowerModeEnabled: false,
    thermalSeverity: .normal, settings: settings
  )
  #expect(first == [.suggestLowPowerMode])
  #expect(second.isEmpty)
}

private func measurement(watts: Double, interval: TimeInterval) -> ProcessEnergyMeasurement {
  ProcessEnergyMeasurement(
    usages: [appUsage(watts: watts)],
    interval: interval,
    measuredProcessCount: 8,
    eligibleProcessCount: 10
  )
}

private func appUsage(watts: Double) -> ApplicationPowerUsage {
  ApplicationPowerUsage(
    applicationName: "Ders",
    bundlePath: "/Applications/Ders.app",
    watts: watts,
    processes: [ProcessPowerUsage(processName: "Ders", watts: watts)]
  )
}

private func historyPoint(at date: Date) -> EnergyHistoryPoint {
  EnergyHistoryPoint(
    date: date,
    batteryWatts: 10,
    batteryPercentage: 75,
    isCharging: false,
    attributedApplicationWatts: 2,
    coverage: 0.8,
    applications: [HistoricalApplicationUsage(applicationName: "Ders", watts: 2)]
  )
}
