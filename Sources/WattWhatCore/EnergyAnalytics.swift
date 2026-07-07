import Foundation

enum EnergyDisplayWindow: Int, CaseIterable, Identifiable {
  case instant = 3
  case thirtySeconds = 30
  case fiveMinutes = 300

  var id: Int { rawValue }
  var title: String {
    switch self {
    case .instant: return "3 sn. anlık"
    case .thirtySeconds: return "30 sn. ortalama"
    case .fiveMinutes: return "5 dk. ortalama"
    }
  }
}

struct SmoothedEnergySnapshot {
  let usages: [ApplicationPowerUsage]
  let attributedTotalWatts: Double
  let coverage: Double
  let sampleCount: Int
}

final class ApplicationPowerTimeline {
  private struct Sample {
    let date: Date
    let measurement: ProcessEnergyMeasurement
  }
  private var samples: [Sample] = []

  func reset() { samples.removeAll() }

  func add(_ measurement: ProcessEnergyMeasurement, at date: Date = Date()) {
    samples.append(Sample(date: date, measurement: measurement))
    samples.removeAll { date.timeIntervalSince($0.date) > 310 }
  }

  func snapshot(window: TimeInterval, now: Date = Date()) -> SmoothedEnergySnapshot? {
    let selected = samples.filter { now.timeIntervalSince($0.date) <= window }
    guard !selected.isEmpty else { return nil }
    let totalDuration = selected.reduce(0) { $0 + max($1.measurement.interval, 0.001) }
    var appEnergy:
      [String: (name: String, path: String, joules: Double, processes: [String: Double])] = [:]

    for sample in selected {
      let duration = max(sample.measurement.interval, 0.001)
      for usage in sample.measurement.usages {
        let key = usage.applicationName.folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: Locale(identifier: "tr_TR")
        )
        var value =
          appEnergy[key]
          ?? (usage.applicationName, usage.bundlePath, 0, [:])
        value.joules += usage.watts * duration
        for process in usage.processes {
          value.processes[process.processName, default: 0] += process.watts * duration
        }
        appEnergy[key] = value
      }
    }

    let usages = appEnergy.values.map { value in
      ApplicationPowerUsage(
        applicationName: value.name,
        bundlePath: value.path,
        watts: value.joules / totalDuration,
        processes: value.processes.map {
          ProcessPowerUsage(processName: $0.key, watts: $0.value / totalDuration)
        }.sorted { $0.watts > $1.watts }
      )
    }.sorted { $0.watts > $1.watts }
    let coverage = selected.reduce(0) { $0 + $1.measurement.coverage } / Double(selected.count)
    return SmoothedEnergySnapshot(
      usages: usages,
      attributedTotalWatts: usages.reduce(0) { $0 + $1.watts },
      coverage: coverage,
      sampleCount: selected.count
    )
  }
}

struct HistoricalApplicationUsage: Codable, Equatable, Identifiable {
  var id: String { applicationName }
  let applicationName: String
  let watts: Double
}

struct EnergyHistoryPoint: Codable, Equatable, Identifiable {
  let id: UUID
  let date: Date
  let batteryWatts: Double
  let batteryPercentage: Double
  let isCharging: Bool
  let attributedApplicationWatts: Double
  let coverage: Double
  let applications: [HistoricalApplicationUsage]

  init(
    id: UUID = UUID(), date: Date, batteryWatts: Double, batteryPercentage: Double,
    isCharging: Bool, attributedApplicationWatts: Double, coverage: Double,
    applications: [HistoricalApplicationUsage]
  ) {
    self.id = id
    self.date = date
    self.batteryWatts = batteryWatts
    self.batteryPercentage = batteryPercentage
    self.isCharging = isCharging
    self.attributedApplicationWatts = attributedApplicationWatts
    self.coverage = coverage
    self.applications = applications
  }
}

final class EnergyHistoryStore {
  private(set) var points: [EnergyHistoryPoint] = []
  private let fileURL: URL
  private let retention: TimeInterval
  private let minimumInterval: TimeInterval

  init(
    fileURL: URL = EnergyHistoryStore.defaultFileURL(),
    retention: TimeInterval = 7 * 24 * 3600,
    minimumInterval: TimeInterval = 30
  ) {
    self.fileURL = fileURL
    self.retention = retention
    self.minimumInterval = minimumInterval
    load()
  }

  @discardableResult
  func append(_ point: EnergyHistoryPoint) -> Bool {
    if let last = points.last, point.date.timeIntervalSince(last.date) < minimumInterval {
      return false
    }
    points.append(point)
    points.removeAll { point.date.timeIntervalSince($0.date) > retention }
    save()
    return true
  }

  func csv() -> String {
    var rows = ["tarih,pil_watt,pil_yuzdesi,durum,uygulama_watt,kapsam,en_cok_tuketenler"]
    let formatter = ISO8601DateFormatter()
    for point in points {
      let apps = point.applications.map { application in
        let watts = String(
          format: "%.3f",
          locale: Locale(identifier: "en_US_POSIX"),
          application.watts
        )
        return "\(application.applicationName):\(watts)W"
      }.joined(separator: " | ").replacingOccurrences(of: "\"", with: "\"\"")
      rows.append(
        [
          formatter.string(from: point.date),
          String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), point.batteryWatts),
          String(
            format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), point.batteryPercentage),
          point.isCharging ? "sarj" : "pil",
          String(
            format: "%.3f", locale: Locale(identifier: "en_US_POSIX"),
            point.attributedApplicationWatts),
          String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), point.coverage * 100),
          "\"\(apps)\"",
        ].joined(separator: ","))
    }
    return rows.joined(separator: "\n") + "\n"
  }

  private func load() {
    guard let data = try? Data(contentsOf: fileURL),
      let decoded = try? JSONDecoder().decode([EnergyHistoryPoint].self, from: data)
    else { return }
    points = decoded
    if let newest = points.last?.date {
      points.removeAll { newest.timeIntervalSince($0.date) > retention }
    }
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(points) else { return }
    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: fileURL, options: .atomic)
  }

  private static func defaultFileURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("WattWhat", isDirectory: true)
      .appendingPathComponent("energy-history.json")
  }
}

enum ThermalSeverity { case normal, warning, critical }

struct SmartAlertSettings {
  var enabled = true
  var applicationThresholdWatts = 5.0
  var sustainedDuration: TimeInterval = 120
  var cooldown: TimeInterval = 1800
}

enum SmartAlertEvent: Equatable {
  case application(name: String, watts: Double)
  case rapidBatteryDrain(percentPerHour: Double)
  case highBatteryTemperature(celsius: Double)
  case thermalPressure
  case suggestLowPowerMode
}

final class SmartAlertEvaluator {
  private var thresholdStart: [String: Date] = [:]
  private var lastAlert: [String: Date] = [:]
  private var batteryObservations: [(Date, Double)] = []
  private var lowPowerSuggested = false

  func evaluate(
    at date: Date, usages: [ApplicationPowerUsage], batteryPercentage: Double,
    isCharging: Bool, batteryTemperature: Double?, lowPowerModeEnabled: Bool,
    thermalSeverity: ThermalSeverity, settings: SmartAlertSettings
  ) -> [SmartAlertEvent] {
    guard settings.enabled else { return [] }
    var events: [SmartAlertEvent] = []
    events += applicationEvents(at: date, usages: usages, settings: settings)

    if isCharging {
      batteryObservations.removeAll()
      lowPowerSuggested = false
    } else {
      batteryObservations.append((date, batteryPercentage))
      batteryObservations.removeAll { date.timeIntervalSince($0.0) > 900 }
      if let first = batteryObservations.first,
        date.timeIntervalSince(first.0) >= 300,
        first.1 > batteryPercentage
      {
        let rate = (first.1 - batteryPercentage) / (date.timeIntervalSince(first.0) / 3600)
        if rate >= 15, canAlert("drain", at: date, cooldown: settings.cooldown) {
          events.append(.rapidBatteryDrain(percentPerHour: rate))
        }
      }
      if batteryPercentage <= 30, !lowPowerModeEnabled, !lowPowerSuggested {
        lowPowerSuggested = true
        events.append(.suggestLowPowerMode)
      }
    }

    if let temperature = batteryTemperature, temperature >= 45,
      canAlert("battery-temperature", at: date, cooldown: settings.cooldown)
    {
      events.append(.highBatteryTemperature(celsius: temperature))
    }
    if thermalSeverity == .critical,
      canAlert("thermal", at: date, cooldown: settings.cooldown)
    {
      events.append(.thermalPressure)
    }
    return events
  }

  private func applicationEvents(
    at date: Date, usages: [ApplicationPowerUsage], settings: SmartAlertSettings
  ) -> [SmartAlertEvent] {
    var events: [SmartAlertEvent] = []
    let active = Set(usages.filter { $0.watts >= settings.applicationThresholdWatts }.map(\.id))
    thresholdStart = thresholdStart.filter { active.contains($0.key) }
    for usage in usages where usage.watts >= settings.applicationThresholdWatts {
      let start = thresholdStart[usage.id] ?? date
      thresholdStart[usage.id] = start
      if date.timeIntervalSince(start) >= settings.sustainedDuration,
        canAlert("app:\(usage.id)", at: date, cooldown: settings.cooldown)
      {
        events.append(.application(name: usage.applicationName, watts: usage.watts))
      }
    }
    return events
  }

  private func canAlert(_ key: String, at date: Date, cooldown: TimeInterval) -> Bool {
    if let last = lastAlert[key], date.timeIntervalSince(last) < cooldown { return false }
    lastAlert[key] = date
    return true
  }
}
