import Foundation
import Testing

@testable import WattWhatCore

@Test("Aynı uygulamanın süreçleri tek watt değerinde birleşir")
func aggregatesProcessesByApplication() {
  let first = ProcessIdentity(pid: 10, startTime: 100)
  let second = ProcessIdentity(pid: 11, startTime: 110)
  let previous = snapshots([
    (first, "Ders", 1_000_000_000),
    (second, "Ders", 2_000_000_000),
  ])
  let current = snapshots([
    (first, "Ders", 2_000_000_000),
    (second, "Ders", 4_000_000_000),
  ])

  let result = ApplicationPowerCalculator.calculate(
    previous: previous,
    current: current,
    interval: 2
  )

  #expect(result.count == 1)
  #expect(result[0].applicationName == "Ders")
  #expect(abs(result[0].watts - 1.5) < 0.0001)
  #expect(result[0].processes.count == 2)
}

@Test("Aynı adlı uygulama farklı bundle yollarında olsa da tek satırda birleşir")
func mergesSameApplicationNameAcrossBundlePaths() {
  let first = ProcessIdentity(pid: 12, startTime: 120)
  let second = ProcessIdentity(pid: 13, startTime: 130)
  let previous = snapshots([
    (first, "Ders", 1_000_000_000),
    (second, "Ders", 1_000_000_000),
  ])
  var current = snapshots([
    (first, "Ders", 2_000_000_000),
    (second, "Ders", 2_000_000_000),
  ])
  let secondSnapshot = current[second]!
  current[second] = ProcessEnergySnapshot(
    identity: second,
    applicationName: secondSnapshot.applicationName,
    bundlePath: "/Users/ugur/Ders.app",
    processName: secondSnapshot.processName,
    energyNanojoules: secondSnapshot.energyNanojoules
  )

  let result = ApplicationPowerCalculator.calculate(
    previous: previous,
    current: current,
    interval: 2
  )

  #expect(result.count == 1)
  #expect(abs(result[0].watts - 1.0) < 0.0001)
}

@Test("PID yeniden kullanılırsa eski sürecin enerjisi hesaba katılmaz")
func ignoresReusedPID() {
  let oldIdentity = ProcessIdentity(pid: 20, startTime: 100)
  let newIdentity = ProcessIdentity(pid: 20, startTime: 200)

  let result = ApplicationPowerCalculator.calculate(
    previous: snapshots([(oldIdentity, "Eski", 1_000)]),
    current: snapshots([(newIdentity, "Yeni", 9_000)]),
    interval: 3
  )

  #expect(result.isEmpty)
}

@Test("Enerji sayacı gerilerse geçersiz örnek yok sayılır")
func ignoresRegressedCounter() {
  let identity = ProcessIdentity(pid: 30, startTime: 300)
  let result = ApplicationPowerCalculator.calculate(
    previous: snapshots([(identity, "Uygulama", 10_000)]),
    current: snapshots([(identity, "Uygulama", 5_000)]),
    interval: 3
  )

  #expect(result.isEmpty)
}

@Test("Yardımcı süreç dıştaki ana uygulama adıyla gruplanır")
func resolvesOutermostApplicationBundle() {
  let path = "/Applications/Ders.app/Contents/Frameworks/Ders Helper.app/Contents/MacOS/Ders Helper"
  #expect(ApplicationNameResolver.application(from: path)?.name == "Ders")
  #expect(ApplicationNameResolver.application(from: path)?.bundlePath == "/Applications/Ders.app")
}

@Test("Uygulama yolu olmayan alt süreç üst uygulamaya bağlanır")
func resolvesApplicationFromParentProcess() {
  let parent = ProcessRecord(
    pid: 40,
    parentPID: 1,
    executablePath: "/Applications/Terminal.app/Contents/MacOS/Terminal"
  )
  let child = ProcessRecord(pid: 41, parentPID: 40, executablePath: "/bin/zsh")
  let records: [Int32: ProcessRecord] = [40: parent, 41: child]

  #expect(ApplicationNameResolver.resolve(for: child, processesByPID: records)?.name == "Terminal")
}

private func snapshots(
  _ values: [(ProcessIdentity, String, UInt64)]
) -> [ProcessIdentity: ProcessEnergySnapshot] {
  Dictionary(
    uniqueKeysWithValues: values.map { identity, name, energy in
      (
        identity,
        ProcessEnergySnapshot(
          identity: identity,
          applicationName: name,
          bundlePath: "/Applications/\(name).app",
          processName: "\(name)-\(identity.pid)",
          energyNanojoules: energy
        )
      )
    })
}
