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
  let energyNanojoules: UInt64
}

struct ApplicationPowerUsage: Equatable {
  let applicationName: String
  let watts: Double
}

enum ProcessEnergySample {
  case warmingUp
  case unavailable
  case available([ApplicationPowerUsage])
}

enum ApplicationPowerCalculator {
  static func calculate(
    previous: [ProcessIdentity: ProcessEnergySnapshot],
    current: [ProcessIdentity: ProcessEnergySnapshot],
    interval: TimeInterval
  ) -> [ApplicationPowerUsage] {
    guard interval > 0 else { return [] }

    var energyByApplication: [String: UInt64] = [:]

    for (identity, currentSnapshot) in current {
      guard let previousSnapshot = previous[identity],
        currentSnapshot.energyNanojoules >= previousSnapshot.energyNanojoules
      else {
        continue
      }

      let delta = currentSnapshot.energyNanojoules - previousSnapshot.energyNanojoules
      guard delta > 0 else { continue }
      energyByApplication[currentSnapshot.applicationName, default: 0] += delta
    }

    return
      energyByApplication
      .map { applicationName, energyNanojoules in
        let joules = Double(energyNanojoules) / 1_000_000_000
        return ApplicationPowerUsage(
          applicationName: applicationName,
          watts: joules / interval
        )
      }
      .sorted {
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

enum ApplicationNameResolver {
  static func resolve(for process: ProcessRecord, processesByPID: [Int32: ProcessRecord]) -> String?
  {
    var currentProcess: ProcessRecord? = process
    var visitedPIDs = Set<Int32>()

    while let candidate = currentProcess,
      visitedPIDs.insert(candidate.pid).inserted
    {
      if let applicationName = applicationName(from: candidate.executablePath) {
        return applicationName
      }
      currentProcess = processesByPID[candidate.parentPID]
    }

    return nil
  }

  static func applicationName(from executablePath: String) -> String? {
    let components = executablePath.split(separator: "/")
    guard let bundleComponent = components.first(where: { $0.lowercased().hasSuffix(".app") })
    else {
      return nil
    }

    return String(bundleComponent.dropLast(4))
  }
}

final class ProcessEnergyMonitor {
  private var previousSnapshots: [ProcessIdentity: ProcessEnergySnapshot]?
  private var previousSampleDate: Date?

  func sample(at now: Date = Date()) -> ProcessEnergySample {
    let currentSnapshots = collectSnapshots()
    guard !currentSnapshots.isEmpty else { return .unavailable }

    defer {
      previousSnapshots = currentSnapshots
      previousSampleDate = now
    }

    guard let previousSnapshots, let previousSampleDate else {
      return .warmingUp
    }

    let usages = ApplicationPowerCalculator.calculate(
      previous: previousSnapshots,
      current: currentSnapshots,
      interval: now.timeIntervalSince(previousSampleDate)
    )
    return .available(Array(usages.prefix(3)))
  }

  private func collectSnapshots() -> [ProcessIdentity: ProcessEnergySnapshot] {
    let processes = runningProcesses()
    let processesByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
    var snapshots: [ProcessIdentity: ProcessEnergySnapshot] = [:]
    let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)

    for process in processes where process.pid != ownPID {
      guard
        let applicationName = ApplicationNameResolver.resolve(
          for: process,
          processesByPID: processesByPID
        ), let resourceUsage = resourceUsage(for: process.pid)
      else {
        continue
      }

      let identity = ProcessIdentity(pid: process.pid, startTime: resourceUsage.startTime)
      snapshots[identity] = ProcessEnergySnapshot(
        identity: identity,
        applicationName: applicationName,
        energyNanojoules: resourceUsage.energyNanojoules
      )
    }

    return snapshots
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
      else {
        return []
      }

      return output.split(separator: "\n").compactMap { line in
        let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
        guard fields.count == 3,
          let pid = Int32(fields[0]),
          let parentPID = Int32(fields[1])
        else {
          return nil
        }
        return ProcessRecord(
          pid: pid,
          parentPID: parentPID,
          executablePath: String(fields[2])
        )
      }
    } catch {
      return []
    }
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
