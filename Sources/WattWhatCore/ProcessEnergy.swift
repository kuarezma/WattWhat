import Darwin
import Foundation

// Swift, void-pointer typedefini yanlış köprülediği için C imzasını doğrudan tanımlıyoruz.
@_silgen_name("proc_pid_rusage")
private func procPIDResourceUsage(
  _ pid: Int32,
  _ flavor: Int32,
  _ buffer: UnsafeMutableRawPointer
) -> Int32

public struct ProcessIdentity: Hashable, Sendable {
  public let pid: Int32
  public let startTime: UInt64

  public init(pid: Int32, startTime: UInt64) {
    self.pid = pid
    self.startTime = startTime
  }
}

public struct ProcessEnergySnapshot: Sendable {
  public let identity: ProcessIdentity
  public let applicationName: String
  public let bundlePath: String
  public let processName: String
  public let energyNanojoules: UInt64

  public init(
    identity: ProcessIdentity,
    applicationName: String,
    bundlePath: String,
    processName: String,
    energyNanojoules: UInt64
  ) {
    self.identity = identity
    self.applicationName = applicationName
    self.bundlePath = bundlePath
    self.processName = processName
    self.energyNanojoules = energyNanojoules
  }
}

public struct ProcessPowerUsage: Equatable, Identifiable, Sendable {
  public var id: String { processName }
  public let processName: String
  public let watts: Double

  public init(processName: String, watts: Double) {
    self.processName = processName
    self.watts = watts
  }
}

public struct ApplicationPowerUsage: Equatable, Identifiable, Sendable {
  public var id: String { bundlePath.isEmpty ? applicationName : bundlePath }
  public let applicationName: String
  public let bundlePath: String
  public let watts: Double
  public let processes: [ProcessPowerUsage]

  public init(
    applicationName: String,
    bundlePath: String,
    watts: Double,
    processes: [ProcessPowerUsage]
  ) {
    self.applicationName = applicationName
    self.bundlePath = bundlePath
    self.watts = watts
    self.processes = processes
  }
}

public struct ProcessEnergyMeasurement: Sendable {
  public let usages: [ApplicationPowerUsage]
  public let interval: TimeInterval
  public let measuredProcessCount: Int
  public let eligibleProcessCount: Int

  public init(
    usages: [ApplicationPowerUsage],
    interval: TimeInterval,
    measuredProcessCount: Int,
    eligibleProcessCount: Int
  ) {
    self.usages = usages
    self.interval = interval
    self.measuredProcessCount = measuredProcessCount
    self.eligibleProcessCount = eligibleProcessCount
  }

  public var attributedTotalWatts: Double { usages.reduce(0) { $0 + $1.watts } }
  public var coverage: Double {
    guard eligibleProcessCount > 0 else { return 0 }
    return Double(measuredProcessCount) / Double(eligibleProcessCount)
  }
}

public enum ProcessEnergySample: Sendable {
  case warmingUp
  case unavailable
  case available(ProcessEnergyMeasurement)
}

public enum ApplicationPowerCalculator {
  private struct ApplicationAccumulator {
    let applicationName: String
    let bundlePath: String
    var energyNanojoules: UInt64 = 0
    var processEnergy: [String: UInt64] = [:]
  }

  public static func calculate(
    previous: [ProcessIdentity: ProcessEnergySnapshot],
    current: [ProcessIdentity: ProcessEnergySnapshot],
    interval: TimeInterval
  ) -> [ApplicationPowerUsage] {
    guard interval > 0 else { return [] }

    var applications: [String: ApplicationAccumulator] = [:]
    for (identity, currentSnapshot) in current {
      guard let previousSnapshot = previous[identity],
        currentSnapshot.energyNanojoules >= previousSnapshot.energyNanojoules
      else { continue }

      let delta = currentSnapshot.energyNanojoules - previousSnapshot.energyNanojoules
      guard delta > 0 else { continue }

      let key = currentSnapshot.applicationName.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "tr_TR")
      )
      var accumulator =
        applications[key]
        ?? ApplicationAccumulator(
          applicationName: currentSnapshot.applicationName,
          bundlePath: currentSnapshot.bundlePath
        )
      accumulator.energyNanojoules += delta
      accumulator.processEnergy[currentSnapshot.processName, default: 0] += delta
      applications[key] = accumulator
    }

    return applications.values.map { application in
      let processes = application.processEnergy.map { name, energy in
        ProcessPowerUsage(
          processName: name,
          watts: Double(energy) / 1_000_000_000 / interval
        )
      }.sorted { $0.watts > $1.watts }
      return ApplicationPowerUsage(
        applicationName: application.applicationName,
        bundlePath: application.bundlePath,
        watts: Double(application.energyNanojoules) / 1_000_000_000 / interval,
        processes: processes
      )
    }.sorted {
      if $0.watts == $1.watts {
        return $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName)
          == .orderedAscending
      }
      return $0.watts > $1.watts
    }
  }
}

public struct ProcessRecord: Sendable {
  public let pid: Int32
  public let parentPID: Int32
  public let executablePath: String

  public init(pid: Int32, parentPID: Int32, executablePath: String) {
    self.pid = pid
    self.parentPID = parentPID
    self.executablePath = executablePath
  }
}

public struct ApplicationDescriptor: Equatable, Sendable {
  public let name: String
  public let bundlePath: String

  public init(name: String, bundlePath: String) {
    self.name = name
    self.bundlePath = bundlePath
  }
}

public enum ApplicationNameResolver {
  public static func resolve(
    for process: ProcessRecord,
    processesByPID: [Int32: ProcessRecord]
  ) -> ApplicationDescriptor? {
    var currentProcess: ProcessRecord? = process
    var visitedPIDs = Set<Int32>()

    while let candidate = currentProcess, visitedPIDs.insert(candidate.pid).inserted {
      if let descriptor = application(from: candidate.executablePath) { return descriptor }
      currentProcess = processesByPID[candidate.parentPID]
    }
    return nil
  }

  public static func application(from executablePath: String) -> ApplicationDescriptor? {
    let components = executablePath.split(separator: "/")
    guard let bundleIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") })
    else { return nil }
    let name = String(components[bundleIndex].dropLast(4))
    let bundlePath = "/" + components[...bundleIndex].joined(separator: "/")
    return ApplicationDescriptor(name: name, bundlePath: bundlePath)
  }
}

public final class ProcessEnergyMonitor {
  private var previousSnapshots: [ProcessIdentity: ProcessEnergySnapshot]?
  private var previousSampleDate: Date?
  private var pathCache: [Int32: String] = [:]

  public init() {}

  public func reset() {
    previousSnapshots = nil
    previousSampleDate = nil
    pathCache.removeAll()
  }

  public func sample(at now: Date = Date()) -> ProcessEnergySample {
    let collection = collectSnapshots()
    guard !collection.snapshots.isEmpty else { return .unavailable }

    defer {
      previousSnapshots = collection.snapshots
      previousSampleDate = now
    }
    guard let previousSnapshots, let previousSampleDate else { return .warmingUp }

    let interval = now.timeIntervalSince(previousSampleDate)
    let usages = ApplicationPowerCalculator.calculate(
      previous: previousSnapshots,
      current: collection.snapshots,
      interval: interval
    )
    return .available(
      ProcessEnergyMeasurement(
        usages: usages,
        interval: interval,
        measuredProcessCount: collection.measuredCount,
        eligibleProcessCount: collection.eligibleCount
      )
    )
  }

  private func collectSnapshots() -> (
    snapshots: [ProcessIdentity: ProcessEnergySnapshot], measuredCount: Int, eligibleCount: Int
  ) {
    let processes = runningProcesses()
    let processesByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
    var snapshots: [ProcessIdentity: ProcessEnergySnapshot] = [:]
    var eligibleCount = 0
    let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)

    for process in processes where process.pid != ownPID {
      guard
        let application = ApplicationNameResolver.resolve(
          for: process,
          processesByPID: processesByPID
        )
      else { continue }
      eligibleCount += 1
      guard let resourceUsage = resourceUsage(for: process.pid) else { continue }

      let identity = ProcessIdentity(pid: process.pid, startTime: resourceUsage.startTime)
      snapshots[identity] = ProcessEnergySnapshot(
        identity: identity,
        applicationName: application.name,
        bundlePath: application.bundlePath,
        processName: (process.executablePath as NSString).lastPathComponent,
        energyNanojoules: resourceUsage.energyNanojoules
      )
    }
    return (snapshots, snapshots.count, eligibleCount)
  }

  private func runningProcesses() -> [ProcessRecord] {
    let estimatedCount = proc_listallpids(nil, 0)
    guard estimatedCount > 0 else { return [] }

    let capacity = Int(estimatedCount) + 64
    var pids = [Int32](repeating: 0, count: capacity)
    let bytesReturned = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
      guard let baseAddress = buffer.baseAddress else { return 0 }
      return proc_listallpids(
        baseAddress, Int32(buffer.count * MemoryLayout<Int32>.stride))
    }
    guard bytesReturned > 0 else { return [] }

    let count = min(capacity, Int(bytesReturned))
    var activePIDs = Set<Int32>()
    activePIDs.reserveCapacity(count)
    var records: [ProcessRecord] = []
    records.reserveCapacity(count)

    var bsdInfo = proc_bsdshortinfo()
    let bsdInfoSize = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
    var pathBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)

    for index in 0..<count {
      let pid = pids[index]
      guard pid > 0 else { continue }
      activePIDs.insert(pid)

      let infoBytes = withUnsafeMutablePointer(to: &bsdInfo) { pointer in
        proc_pidinfo(
          pid,
          PROC_PIDT_SHORTBSDINFO,
          0,
          pointer,
          bsdInfoSize
        )
      }
      guard infoBytes == bsdInfoSize else { continue }
      let parentPID = Int32(bsdInfo.pbsi_ppid)

      let executablePath: String
      if let cached = pathCache[pid] {
        executablePath = cached
      } else {
        let pathLen = pathBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
          guard let base = buffer.baseAddress else { return 0 }
          return proc_pidpath(pid, base, UInt32(buffer.count))
        }
        if pathLen > 0 {
          let resolved = String(decoding: pathBuffer.prefix(Int(pathLen)), as: UTF8.self)
          pathCache[pid] = resolved
          executablePath = resolved
        } else {
          let commName = withUnsafePointer(to: bsdInfo.pbsi_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
              String(cString: $0)
            }
          }
          guard !commName.isEmpty else { continue }
          executablePath = commName
        }
      }

      records.append(
        ProcessRecord(
          pid: pid,
          parentPID: parentPID,
          executablePath: executablePath
        )
      )
    }

    if pathCache.count > activePIDs.count + 128 {
      pathCache = pathCache.filter { activePIDs.contains($0.key) }
    }
    return records
  }

  private func resourceUsage(for pid: Int32) -> (startTime: UInt64, energyNanojoules: UInt64)? {
    var resourceUsage = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &resourceUsage) { pointer in
      procPIDResourceUsage(pid, RUSAGE_INFO_V6, UnsafeMutableRawPointer(pointer))
    }
    guard result == 0 else { return nil }
    return (resourceUsage.ri_proc_start_abstime, resourceUsage.ri_energy_nj)
  }
}
