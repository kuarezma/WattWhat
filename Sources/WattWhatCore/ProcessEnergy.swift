import Darwin
import Foundation

// Swift, void-pointer typedefini yanlış köprülediği için C imzasını doğrudan tanımlıyoruz.
@_silgen_name("proc_pid_rusage")
private func procPIDResourceUsage(
  _ pid: Int32,
  _ flavor: Int32,
  _ buffer: UnsafeMutableRawPointer
) -> Int32

struct ProcessIdentity: Hashable {
  let pid: Int32
  let startTime: UInt64
}

struct ProcessEnergySnapshot {
  let identity: ProcessIdentity
  let applicationName: String
  let bundlePath: String
  let processName: String
  let energyNanojoules: UInt64
}

struct ProcessPowerUsage: Equatable, Identifiable {
  var id: String { processName }
  let processName: String
  let watts: Double
}

struct ApplicationPowerUsage: Equatable, Identifiable {
  var id: String { bundlePath.isEmpty ? applicationName : bundlePath }
  let applicationName: String
  let bundlePath: String
  let watts: Double
  let processes: [ProcessPowerUsage]
}

struct ProcessEnergyMeasurement {
  let usages: [ApplicationPowerUsage]
  let interval: TimeInterval
  let measuredProcessCount: Int
  let eligibleProcessCount: Int

  var attributedTotalWatts: Double { usages.reduce(0) { $0 + $1.watts } }
  var coverage: Double {
    guard eligibleProcessCount > 0 else { return 0 }
    return Double(measuredProcessCount) / Double(eligibleProcessCount)
  }
}

enum ProcessEnergySample {
  case warmingUp
  case unavailable
  case available(ProcessEnergyMeasurement)
}

enum ApplicationPowerCalculator {
  private struct ApplicationAccumulator {
    let applicationName: String
    let bundlePath: String
    var energyNanojoules: UInt64 = 0
    var processEnergy: [String: UInt64] = [:]
  }

  static func calculate(
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

struct ProcessRecord {
  let pid: Int32
  let parentPID: Int32
  let executablePath: String
}

struct ApplicationDescriptor: Equatable {
  let name: String
  let bundlePath: String
}

enum ApplicationNameResolver {
  static func resolve(
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

  static func application(from executablePath: String) -> ApplicationDescriptor? {
    let components = executablePath.split(separator: "/")
    guard let bundleIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") })
    else { return nil }
    let name = String(components[bundleIndex].dropLast(4))
    let bundlePath = "/" + components[...bundleIndex].joined(separator: "/")
    return ApplicationDescriptor(name: name, bundlePath: bundlePath)
  }
}

final class ProcessEnergyMonitor {
  private var previousSnapshots: [ProcessIdentity: ProcessEnergySnapshot]?
  private var previousSampleDate: Date?

  func reset() {
    previousSnapshots = nil
    previousSampleDate = nil
  }

  func sample(at now: Date = Date()) -> ProcessEnergySample {
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
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "pid=,ppid=,comm="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    do {
      try task.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      task.waitUntilExit()
      guard task.terminationStatus == 0,
        let output = String(data: data, encoding: .utf8)
      else { return [] }
      return output.split(separator: "\n").compactMap { line in
        let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
        guard fields.count == 3,
          let pid = Int32(fields[0]),
          let parentPID = Int32(fields[1])
        else { return nil }
        return ProcessRecord(
          pid: pid,
          parentPID: parentPID,
          executablePath: String(fields[2])
        )
      }
    } catch { return [] }
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
