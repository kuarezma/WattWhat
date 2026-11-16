import Foundation

public enum EnergyDisplayWindow: Int, CaseIterable, Identifiable, Sendable {
  case instant = 3
  case thirtySeconds = 30
  case fiveMinutes = 300

  public var id: Int { rawValue }
  public var title: String {
    switch self {
    case .instant: return "3 sn. anlık"
    case .thirtySeconds: return "30 sn. ortalama"
    case .fiveMinutes: return "5 dk. ortalama"
    }
  }
}

public struct SmoothedEnergySnapshot: Sendable {
  public let usages: [ApplicationPowerUsage]
  public let attributedTotalWatts: Double
  public let coverage: Double
  public let sampleCount: Int

  public init(
    usages: [ApplicationPowerUsage],
    attributedTotalWatts: Double,
    coverage: Double,
    sampleCount: Int
  ) {
    self.usages = usages
    self.attributedTotalWatts = attributedTotalWatts
    self.coverage = coverage
    self.sampleCount = sampleCount
  }
}

public final class ApplicationPowerTimeline {
  private struct Sample {
    let date: Date
    let measurement: ProcessEnergyMeasurement
  }
  private var samples: [Sample] = []

  public init() {}

  public func reset() { samples.removeAll() }

  public func add(_ measurement: ProcessEnergyMeasurement, at date: Date = Date()) {
    samples.append(Sample(date: date, measurement: measurement))
    samples.removeAll { date.timeIntervalSince($0.date) > 310 }
  }

  public func snapshot(window: TimeInterval, now: Date = Date()) -> SmoothedEnergySnapshot? {
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

public struct HistoricalApplicationUsage: Codable, Equatable, Identifiable, Sendable {
  public var id: String { applicationName }
  public let applicationName: String
  public let watts: Double

  public init(applicationName: String, watts: Double) {
    self.applicationName = applicationName
    self.watts = watts
  }
}

public struct EnergyHistoryPoint: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let date: Date
  public let batteryWatts: Double
  public let batteryPercentage: Double
  public let isCharging: Bool
  public let attributedApplicationWatts: Double
  public let coverage: Double
  public let applications: [HistoricalApplicationUsage]

  public init(
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

public final class EnergyHistoryStore: @unchecked Sendable {
  private let lock = NSLock()
  private var _points: [EnergyHistoryPoint] = []
  private let fileURL: URL
  private let retention: TimeInterval
  private let minimumInterval: TimeInterval
  private let saveInterval: TimeInterval
  private let maxPoints: Int
  private var lastSaveDate: Date?
  private var isDirty = false
  private let ioQueue = DispatchQueue(label: "com.kuarezma.wattwhat.history-io", qos: .utility)

  public var points: [EnergyHistoryPoint] {
    lock.lock()
    defer { lock.unlock() }
    return _points
  }

  public init(
    fileURL: URL = EnergyHistoryStore.defaultFileURL(),
    retention: TimeInterval = 7 * 24 * 3600,
    minimumInterval: TimeInterval = 60,
    saveInterval: TimeInterval = 0,
    maxPoints: Int = 2_880
  ) {
    self.fileURL = fileURL
    self.retention = retention
    self.minimumInterval = minimumInterval
    self.saveInterval = saveInterval
    self.maxPoints = maxPoints
    load()
  }

  @discardableResult
  public func append(_ point: EnergyHistoryPoint) -> Bool {
    var syncSnapshot: [EnergyHistoryPoint]?
    var asyncSnapshot: [EnergyHistoryPoint]?

    lock.lock()
    if let last = _points.last, point.date.timeIntervalSince(last.date) < minimumInterval {
      lock.unlock()
      return false
    }
    let compacted = Self.compact(point)
    _points.append(compacted)
    _points.removeAll { compacted.date.timeIntervalSince($0.date) > retention }
    trimExcessPointsLocked()
    isDirty = true

    if saveInterval <= 0 {
      lastSaveDate = compacted.date
      isDirty = false
      syncSnapshot = _points
    } else if let lastSaveDate, compacted.date.timeIntervalSince(lastSaveDate) < saveInterval {
      // Disk yazımını biriktir (coalesce)
    } else {
      lastSaveDate = compacted.date
      isDirty = false
      asyncSnapshot = _points
    }
    lock.unlock()

    if let syncSnapshot {
      ioQueue.sync {
        saveNow(pointsSnapshot: syncSnapshot)
      }
    } else if let asyncSnapshot {
      ioQueue.async { [weak self] in
        self?.saveNow(pointsSnapshot: asyncSnapshot)
      }
    }
    return true
  }

  public func flush() {
    let snapshot: [EnergyHistoryPoint]?
    lock.lock()
    if isDirty {
      isDirty = false
      snapshot = _points
    } else {
      snapshot = nil
    }
    lock.unlock()

    guard let snapshot else { return }
    ioQueue.sync {
      saveNow(pointsSnapshot: snapshot)
    }
  }

  private static func compact(_ point: EnergyHistoryPoint) -> EnergyHistoryPoint {
    let topApps = point.applications
      .filter { $0.watts >= 0.01 }
      .prefix(5)
      .map {
        HistoricalApplicationUsage(
          applicationName: $0.applicationName,
          watts: ($0.watts * 1000).rounded() / 1000
        )
      }
    return EnergyHistoryPoint(
      id: point.id,
      date: Date(timeIntervalSince1970: point.date.timeIntervalSince1970.rounded()),
      batteryWatts: (point.batteryWatts * 1000).rounded() / 1000,
      batteryPercentage: (point.batteryPercentage * 10).rounded() / 10,
      isCharging: point.isCharging,
      attributedApplicationWatts: (point.attributedApplicationWatts * 1000).rounded() / 1000,
      coverage: (point.coverage * 1000).rounded() / 1000,
      applications: Array(topApps)
    )
  }

  private func trimExcessPointsLocked() {
    guard _points.count > maxPoints else { return }
    // Eski yarısını seyrelterek (her 2 noktadan 1'ini tutarak) uzun dönem geçmişi koru
    let splitIndex = _points.count / 2
    let olderDownsampled = _points[..<splitIndex].enumerated().compactMap { index, element in
      index.isMultiple(of: 2) ? element : nil
    }
    let newerSlice = _points[splitIndex...]
    _points = olderDownsampled + newerSlice
    if _points.count > maxPoints {
      _points.removeFirst(_points.count - maxPoints)
    }
  }

  public func csv() -> String {
    lock.lock()
    let snapshot = _points
    lock.unlock()

    var rows = ["tarih,pil_watt,pil_yuzdesi,durum,uygulama_watt,kapsam,en_cok_tuketenler"]
    let formatter = ISO8601DateFormatter()
    for point in snapshot {
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
    let originalCount = decoded.count
    let originalByteCount = data.count
    var loadedPoints = decoded.map { Self.compact($0) }
    if let newest = loadedPoints.last?.date {
      loadedPoints.removeAll { newest.timeIntervalSince($0.date) > retention }
    }

    var snapshotToSave: [EnergyHistoryPoint]?
    lock.lock()
    _points = loadedPoints
    trimExcessPointsLocked()
    if _points.count < originalCount || originalByteCount > 1_000_000 {
      snapshotToSave = _points
    }
    lock.unlock()

    if let snapshotToSave {
      ioQueue.async { [weak self] in
        self?.saveNow(pointsSnapshot: snapshotToSave)
      }
    }
  }

  private func saveNow(pointsSnapshot: [EnergyHistoryPoint]) {
    guard let data = try? JSONEncoder().encode(pointsSnapshot) else { return }
    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: fileURL, options: .atomic)
  }

  public static func defaultFileURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("WattWhat", isDirectory: true)
      .appendingPathComponent("energy-history.json")
  }
}

public enum ThermalSeverity: Sendable { case normal, warning, critical }

public struct SmartAlertSettings: Sendable {
  public var enabled = true
  public var applicationThresholdWatts = 5.0
  public var sustainedDuration: TimeInterval = 120
  public var cooldown: TimeInterval = 1800

  public init(
    enabled: Bool = true,
    applicationThresholdWatts: Double = 5.0,
    sustainedDuration: TimeInterval = 120,
    cooldown: TimeInterval = 1800
  ) {
    self.enabled = enabled
    self.applicationThresholdWatts = applicationThresholdWatts
    self.sustainedDuration = sustainedDuration
    self.cooldown = cooldown
  }
}

public enum SmartAlertEvent: Equatable, Sendable {
  case application(name: String, watts: Double)
  case rapidBatteryDrain(percentPerHour: Double)
  case highBatteryTemperature(celsius: Double)
  case thermalPressure
  case suggestLowPowerMode
}

public final class SmartAlertEvaluator {
  private var thresholdStart: [String: Date] = [:]
  private var lastAlert: [String: Date] = [:]
  private var batteryObservations: [(Date, Double)] = []
  private var lowPowerSuggested = false

  public init() {}

  public func evaluate(
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
