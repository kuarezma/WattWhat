import Foundation
import IOKit
import IOKit.ps

struct USBPDProfile: Codable, Equatable, Identifiable, Sendable {
  var id: Int { index }
  let index: Int
  let maxVoltage_mV: Int
  let maxCurrent_mA: Int

  var maxVoltage_V: Double { Double(maxVoltage_mV) / 1_000.0 }
  var maxCurrent_A: Double { Double(maxCurrent_mA) / 1_000.0 }
  var maxWatts: Double { (Double(maxVoltage_mV) * Double(maxCurrent_mA)) / 1_000_000.0 }
}

struct LivePowerTelemetry: Codable, Equatable, Sendable {
  let timestamp: Date
  let isPluggedIn: Bool
  let isCharging: Bool
  let isFullyCharged: Bool
  let batteryPercent: Double
  let batteryVoltage_V: Double
  let batteryCurrent_A: Double
  let batteryChargeWatts: Double
  let adapterRatingWatts: Int
  let adapterVoltage_V: Double
  let adapterCurrent_A: Double
  let systemInputWatts: Double
  let systemLoadWatts: Double
  let efficiencyLossWatts: Double
  let pmuConfiguredCurrent_mA: Int
  let ipdWattageOverride_mW: Int
  let activePDOIndex: Int?
  let pdoProfiles: [USBPDProfile]
  let batteryTemp_C: Double?
  let notChargingReason: Int
  let slowChargingReason: Int

  /// Anlık pil net gücü (şarjda pozitif, deşarjda negatif kabul eden yerler için büyüklük).
  var signedBatteryWatts: Double {
    if isCharging { return abs(batteryChargeWatts) }
    if batteryCurrent_A < 0 { return -abs(batteryChargeWatts) }
    return batteryChargeWatts
  }

  static let empty = LivePowerTelemetry(
    timestamp: Date(),
    isPluggedIn: false,
    isCharging: false,
    isFullyCharged: false,
    batteryPercent: 0,
    batteryVoltage_V: 0,
    batteryCurrent_A: 0,
    batteryChargeWatts: 0,
    adapterRatingWatts: 0,
    adapterVoltage_V: 0,
    adapterCurrent_A: 0,
    systemInputWatts: 0,
    systemLoadWatts: 0,
    efficiencyLossWatts: 0,
    pmuConfiguredCurrent_mA: 0,
    ipdWattageOverride_mW: 0,
    activePDOIndex: nil,
    pdoProfiles: [],
    batteryTemp_C: nil,
    notChargingReason: 0,
    slowChargingReason: 0
  )
}

enum PowerTelemetryReader {
  private static func signedInt64Value(_ raw: Any?) -> Int64? {
    if let number = raw as? NSNumber {
      return Int64(bitPattern: number.uint64Value)
    }
    if let intVal = raw as? Int {
      return Int64(intVal)
    }
    return nil
  }

  private static func intValue(_ raw: Any?) -> Int? {
    if let intVal = raw as? Int { return intVal }
    if let number = raw as? NSNumber { return number.intValue }
    return nil
  }

  static func read(now: Date = Date()) -> LivePowerTelemetry {
    var isPluggedIn = false
    var isCharging = false
    var isFullyCharged = false
    var batteryPercent = 0.0
    var batteryVoltage_V = 0.0
    var batteryCurrent_A = 0.0
    var batteryChargeWatts = 0.0
    var adapterRatingWatts = 0
    var adapterVoltage_V = 0.0
    var adapterCurrent_A = 0.0
    var systemInputWatts = 0.0
    var systemLoadWatts = 0.0
    var efficiencyLossWatts = 0.0
    var pmuConfiguredCurrent_mA = 0
    var ipdWattageOverride_mW = 0
    var activePDOIndex: Int?
    var pdoProfiles: [USBPDProfile] = []
    var batteryTemp_C: Double?
    var notChargingReason = 0
    var slowChargingReason = 0

    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    if service != 0 {
      defer { IOObjectRelease(service) }

      if let extConn = IORegistryEntryCreateCFProperty(
        service, "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        as? Bool
      {
        isPluggedIn = extConn
      }
      if let chargingProp = IORegistryEntryCreateCFProperty(
        service, "IsCharging" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
      {
        isCharging = chargingProp
      }
      if let fullProp = IORegistryEntryCreateCFProperty(
        service, "FullyCharged" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
      {
        isFullyCharged = fullProp
      }
      if let currCap = intValue(
        IORegistryEntryCreateCFProperty(
          service, "CurrentCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()),
        let maxCap = intValue(
          IORegistryEntryCreateCFProperty(
            service, "MaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()),
        maxCap > 0
      {
        batteryPercent = (Double(currCap) / Double(maxCap)) * 100.0
      }

      let voltageRaw = IORegistryEntryCreateCFProperty(
        service, "Voltage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      let amperageRaw = IORegistryEntryCreateCFProperty(
        service, "Amperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      if let voltage_mV = signedInt64Value(voltageRaw),
        let amperage_mA = signedInt64Value(amperageRaw),
        voltage_mV > 0
      {
        batteryVoltage_V = Double(voltage_mV) / 1_000.0
        batteryCurrent_A = Double(amperage_mA) / 1_000.0
        batteryChargeWatts = abs(Double(voltage_mV) * Double(amperage_mA)) / 1_000_000.0
      }

      if let tempRaw = intValue(
        IORegistryEntryCreateCFProperty(
          service, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()),
        tempRaw > 0
      {
        batteryTemp_C = Double(tempRaw) / 100.0
      }

      if let adapterDetails = IORegistryEntryCreateCFProperty(
        service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        as? [String: Any]
      {
        if let watts = intValue(adapterDetails["Watts"]) {
          adapterRatingWatts = watts
        }
        if let v_mV = intValue(adapterDetails["AdapterVoltage"]), v_mV > 0 {
          adapterVoltage_V = Double(v_mV) / 1_000.0
        }
        if let c_mA = intValue(adapterDetails["Current"]), c_mA >= 0 {
          adapterCurrent_A = Double(c_mA) / 1_000.0
        }
        if let hvcIdx = intValue(adapterDetails["UsbHvcHvcIndex"]) {
          activePDOIndex = hvcIdx
        }
        if let menu = adapterDetails["UsbHvcMenu"] as? [[String: Any]] {
          pdoProfiles = menu.compactMap { entry in
            guard let idx = intValue(entry["Index"]),
              let maxV = intValue(entry["MaxVoltage"]),
              let maxC = intValue(entry["MaxCurrent"])
            else { return nil }
            return USBPDProfile(index: idx, maxVoltage_mV: maxV, maxCurrent_mA: maxC)
          }.sorted { $0.index < $1.index }
        }
      }

      if let powerDist = IORegistryEntryCreateCFProperty(
        service, "PowerDistribution" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        as? [String: Any]
      {
        if let override_mW = intValue(powerDist["IPDWattageOverride"]) {
          ipdWattageOverride_mW = override_mW
        }
      }

      if let chargerData = IORegistryEntryCreateCFProperty(
        service, "ChargerData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        as? [String: Any]
      {
        if let pmuConf = intValue(chargerData["PMUConfigured"]) {
          pmuConfiguredCurrent_mA = pmuConf
        }
        if let ncr = intValue(chargerData["NotChargingReason"]) {
          notChargingReason = ncr
        }
        if let scr = intValue(chargerData["SlowChargingReason"]) {
          slowChargingReason = scr
        }
      }

      if let telemetry = IORegistryEntryCreateCFProperty(
        service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        as? [String: Any]
      {
        if let sysIn = signedInt64Value(telemetry["SystemPowerIn"]), sysIn >= 0, sysIn < 250_000 {
          systemInputWatts = Double(sysIn) / 1_000.0
        }
        if let sysLoad = signedInt64Value(telemetry["SystemLoad"]), sysLoad >= 0, sysLoad < 250_000
        {
          systemLoadWatts = Double(sysLoad) / 1_000.0
        }
        if let loss = signedInt64Value(telemetry["AdapterEfficiencyLoss"]), loss >= 0,
          loss < 100_000
        {
          efficiencyLossWatts = Double(loss) / 1_000.0
        }
        if let vIn = signedInt64Value(telemetry["SystemVoltageIn"]), vIn > 0, vIn < 100_000 {
          adapterVoltage_V = Double(vIn) / 1_000.0
        }
        if let cIn = signedInt64Value(telemetry["SystemCurrentIn"]), cIn >= 0, cIn < 100_000 {
          adapterCurrent_A = Double(cIn) / 1_000.0
        }
        if batteryChargeWatts < 0.05,
          let battPow = signedInt64Value(telemetry["BatteryPower"]),
          battPow != 0, abs(battPow) < 250_000
        {
          batteryChargeWatts = abs(Double(battPow)) / 1_000.0
        }
      }
    }

    // IOPS ile destekle (özellikle yüzde ve fiş/şarj durumu tutarlılığı için)
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
    for source in sources {
      guard
        let info = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue()
          as? [String: Any]
      else { continue }
      let type = info[kIOPSTypeKey] as? String ?? ""
      if type != kIOPSInternalBatteryType { continue }
      let state = info[kIOPSPowerSourceStateKey] as? String ?? ""
      isPluggedIn = (state == kIOPSACPowerValue) || isPluggedIn
      if let iopsCharging = info[kIOPSIsChargingKey] as? Bool {
        isCharging = iopsCharging
      }
      if let iopsFull = info[kIOPSIsChargedKey] as? Bool {
        isFullyCharged = iopsFull
      }
      let curr = info[kIOPSCurrentCapacityKey] as? Int ?? 0
      let maxCap = info[kIOPSMaxCapacityKey] as? Int ?? 100
      if maxCap > 0 {
        batteryPercent = (Double(curr) / Double(maxCap)) * 100.0
      }
    }

    return LivePowerTelemetry(
      timestamp: now,
      isPluggedIn: isPluggedIn,
      isCharging: isCharging,
      isFullyCharged: isFullyCharged,
      batteryPercent: batteryPercent,
      batteryVoltage_V: batteryVoltage_V,
      batteryCurrent_A: batteryCurrent_A,
      batteryChargeWatts: batteryChargeWatts,
      adapterRatingWatts: adapterRatingWatts,
      adapterVoltage_V: adapterVoltage_V,
      adapterCurrent_A: adapterCurrent_A,
      systemInputWatts: systemInputWatts,
      systemLoadWatts: systemLoadWatts,
      efficiencyLossWatts: efficiencyLossWatts,
      pmuConfiguredCurrent_mA: pmuConfiguredCurrent_mA,
      ipdWattageOverride_mW: ipdWattageOverride_mW,
      activePDOIndex: activePDOIndex,
      pdoProfiles: pdoProfiles,
      batteryTemp_C: batteryTemp_C,
      notChargingReason: notChargingReason,
      slowChargingReason: slowChargingReason
    )
  }
}
