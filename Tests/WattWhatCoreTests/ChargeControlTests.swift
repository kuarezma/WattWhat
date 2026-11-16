import Foundation
import Testing

@testable import WattWhatCore

@Test("AppleSMC struct boyutu 80 byte ve little-endian kodlama tutarlıdır")
func smcStructAndEncodingAreAccurate() {
  #expect(MemoryLayout<AppleSMCClient.SMCKeyData>.size == 80)

  let encoded30k = AppleSMCClient.encodeUInt32LE(30_000)
  #expect(encoded30k == [0x30, 0x75, 0x00, 0x00])
  #expect(AppleSMCClient.decodeUInt32LE(encoded30k) == 30_000)

  let encoded1424 = AppleSMCClient.encodeUInt32LE(1_424)
  #expect(encoded1424 == [0x90, 0x05, 0x00, 0x00])
  #expect(AppleSMCClient.decodeUInt32LE(encoded1424) == 1_424)
}

@Test("Otomatik modda macOS kontrolüne devredilir")
func automaticModeRestoresOSControl() {
  let config = ChargeControlConfig.defaultConfig
  let eval = ChargePolicyEvaluator.evaluate(
    config: config,
    telemetry: sampleTelemetry(percent: 55, temp: 30)
  )
  #expect(eval.command == .restoreAutomatic(reason: "macOS otomatik güç yönetimi devrede"))
  #expect(!eval.isInHysteresisHold)
}

@Test("Manuel modda %80 tavanı ve %5 histerezis yelken döngüsü doğru çalışır")
func manualModeCeilingAndHysteresisHoldWork() {
  var config = ChargeControlConfig.defaultConfig
  config.mode = .manualWatts
  config.targetWatts = 18
  config.maxChargeLimitPercent = 80
  config.hysteresisPercent = 5

  // %80'e ulaşınca durdur
  let atLimit = ChargePolicyEvaluator.evaluate(
    config: config,
    telemetry: sampleTelemetry(percent: 80, temp: 31),
    wasInHysteresisHold: false
  )
  #expect(atLimit.isInHysteresisHold)
  if case .inhibitCharging = atLimit.command {
    // beklenen
  } else {
    Issue.record("80% sınırında inhibitCharging bekleniyordu")
  }

  // %77'deyken histerezis içinde kaldığı için hâlâ durdurmalı
  let insideHysteresis = ChargePolicyEvaluator.evaluate(
    config: config,
    telemetry: sampleTelemetry(percent: 77, temp: 31),
    wasInHysteresisHold: true
  )
  #expect(insideHysteresis.isInHysteresisHold)
  if case .inhibitCharging = insideHysteresis.command {
    // beklenen
  } else {
    Issue.record("77% histerezis aralığında inhibitCharging bekleniyordu")
  }

  // %75'e düşünce yeniden 18W ile şarja başlamalı
  let resumed = ChargePolicyEvaluator.evaluate(
    config: config,
    telemetry: sampleTelemetry(percent: 75, temp: 31),
    wasInHysteresisHold: true
  )
  #expect(!resumed.isInHysteresisHold)
  if case .limitWatts(let watts, _, _, _, _) = resumed.command {
    #expect(watts == 18)
  } else {
    Issue.record("75% seviyesinde 18W limitWatts bekleniyordu")
  }
}

@Test("Tek seferlik %100 Top-Up hedef dolduğunda otomatik sıfırlanır")
func topUpTo100ClearsAtFullCharge() {
  var config = ChargeControlConfig.defaultConfig
  config.mode = .manualWatts
  config.targetWatts = 25
  config.maxChargeLimitPercent = 80
  config.topUpTo100Active = true

  let chargingAt90 = ChargePolicyEvaluator.evaluate(
    config: config,
    telemetry: sampleTelemetry(percent: 90, temp: 32)
  )
  if case .limitWatts(let watts, _, let maxPct, _, _) = chargingAt90.command {
    #expect(watts == 25)
    #expect(maxPct == 100)
    #expect(chargingAt90.updatedConfig.topUpTo100Active)
  } else {
    Issue.record("Top-Up aktifken 90%'da şarj devam etmeliydi")
  }

  let fullAt100 = ChargePolicyEvaluator.evaluate(
    config: config,
    telemetry: sampleTelemetry(percent: 100, temp: 30, isFullyCharged: true)
  )
  #expect(!fullAt100.updatedConfig.topUpTo100Active)
}

@Test("Termal koruma ve 43°C acil durdurma çalışır")
func thermalProtectionAndEmergencyCutoff() {
  var config = ChargeControlConfig.defaultConfig
  config.mode = .manualWatts
  config.targetWatts = 30
  config.thermalProtectionEnabled = true
  config.maxBatteryTempCelsius = 38.0
  config.thermalFallbackWatts = 8

  let warm = ChargePolicyEvaluator.evaluate(
    config: config,
    telemetry: sampleTelemetry(percent: 45, temp: 39.0)
  )
  if case .limitWatts(let watts, _, _, _, _) = warm.command {
    #expect(watts == 8)
  } else {
    Issue.record("39°C sıcaklıkta 8W termal kısma bekleniyordu")
  }

  let critical = ChargePolicyEvaluator.evaluate(
    config: config,
    telemetry: sampleTelemetry(percent: 45, temp: 43.2)
  )
  if case .inhibitCharging = critical.command {
    // beklenen
  } else {
    Issue.record("43.2°C kritik sıcaklıkta acil durdurma bekleniyordu")
  }
}

@Test("Gece sessiz şarj penceresi gece yarısını aşsa da doğru çalışır")
func nightQuietWindowHandlesMidnightWrap() {
  #expect(ChargePolicyEvaluator.isWithinHourWindow(hour: 23, startHour: 23, endHour: 7))
  #expect(ChargePolicyEvaluator.isWithinHourWindow(hour: 3, startHour: 23, endHour: 7))
  #expect(!ChargePolicyEvaluator.isWithinHourWindow(hour: 7, startHour: 23, endHour: 7))
  #expect(!ChargePolicyEvaluator.isWithinHourWindow(hour: 15, startHour: 23, endHour: 7))

  var config = ChargeControlConfig.defaultConfig
  config.mode = .manualWatts
  config.targetWatts = 30
  config.nightQuietModeEnabled = true
  config.nightStartHour = 23
  config.nightEndHour = 7
  config.nightWatts = 7
  config.nightTurnOffLED = true

  var comps = DateComponents(year: 2026, month: 11, day: 15, hour: 2, minute: 30)
  let cal = Calendar(identifier: .gregorian)
  comps.calendar = cal
  let nightDate = comps.date!

  let eval = ChargePolicyEvaluator.evaluate(
    config: config,
    telemetry: sampleTelemetry(percent: 40, temp: 28),
    now: nightDate,
    calendar: cal
  )
  if case .limitWatts(let watts, _, _, _, _) = eval.command {
    #expect(watts == 7)
  } else {
    Issue.record("Gece saatinde 7W hedefi bekleniyordu")
  }
  #expect(eval.effectiveLED == .off)
}

@Test("3 kademeli özel şarj eğrisi yüzdelere göre Watt seçer")
func customChargeCurveSelectsExpectedStages() {
  var config = ChargeControlConfig.defaultConfig
  config.mode = .manualWatts
  config.customCurveEnabled = true
  config.maxChargeLimitPercent = 100
  config.curveStages = [
    ChargeCurveStage(upToPercent: 50, watts: 35),
    ChargeCurveStage(upToPercent: 80, watts: 15),
    ChargeCurveStage(upToPercent: 100, watts: 6),
  ]

  let s1 = ChargePolicyEvaluator.evaluate(config: config, telemetry: sampleTelemetry(percent: 30, temp: 29))
  let s2 = ChargePolicyEvaluator.evaluate(config: config, telemetry: sampleTelemetry(percent: 65, temp: 29))
  let s3 = ChargePolicyEvaluator.evaluate(config: config, telemetry: sampleTelemetry(percent: 90, temp: 29))

  if case .limitWatts(let w1, _, _, _, _) = s1.command,
     case .limitWatts(let w2, _, _, _, _) = s2.command,
     case .limitWatts(let w3, _, _, _, _) = s3.command
  {
    #expect(w1 == 35)
    #expect(w2 == 15)
    #expect(w3 == 6)
  } else {
    Issue.record("Özel eğri kademeleri limitWatts döndürmeliydi")
  }
}

@Test("Deşarj modu %15 güvenlik kilidinde otomatik durur")
func forceDischargeEnforcesSafetyFloorAt15Percent() {
  var config = ChargeControlConfig.defaultConfig
  config.mode = .forceDischarge
  config.dischargeTargetPercent = 20

  let evalLow = ChargePolicyEvaluator.evaluate(
    config: config,
    telemetry: sampleTelemetry(percent: 14.5, temp: 29)
  )
  #expect(evalLow.updatedConfig.mode == .passthroughHold)
  if case .inhibitCharging = evalLow.command {
    // beklenen
  } else {
    Issue.record("%15 altında güvenlik kilidi inhibitCharging döndürmeliydi")
  }
}

@Test("SMCKeyDiagnostic bit 7 okuma ve bit 6 yazma bayraklarını doğru yorumlar")
func smcKeyDiagnosticReadWriteBitmasks() {
  let readOnly = SMCKeyDiagnostic(
    key: "BTIL", dataType: "ui8", dataSize: 1, attributes: 0x94,
    currentHex: "00", numericSummary: "0", lastWriteResult: nil
  )
  #expect(readOnly.isReadableFlag)
  #expect(!readOnly.isWritableFlag)

  let readWrite = SMCKeyDiagnostic(
    key: "CHIE", dataType: "ui8", dataSize: 1, attributes: 0xd4,
    currentHex: "00", numericSummary: "0", lastWriteResult: nil
  )
  #expect(readWrite.isReadableFlag)
  #expect(readWrite.isWritableFlag)

  let writeOnly = SMCKeyDiagnostic(
    key: "D1BI", dataType: "ui8", dataSize: 1, attributes: 0x54,
    currentHex: "(write-only)", numericSummary: "salt-yazılır", lastWriteResult: nil
  )
  #expect(!writeOnly.isReadableFlag)
  #expect(writeOnly.isWritableFlag)
}

@Test("AppleSMCClient eski salt-okunur veya ACLC içeren baseline snapshot'ını tespit eder")
func baselineLegacyReadOnlyKeyDetection() {
  let legacySnapshot = SMCBaselineSnapshot(
    capturedAt: Date(),
    keys: ["CHIE": [0x00], "BTIL": [0x01], "ACLC": [0x03]]
  )
  #expect(AppleSMCClient.baselineContainsLegacyReadOnlyKeys(legacySnapshot))

  let cleanSnapshot = SMCBaselineSnapshot(
    capturedAt: Date(),
    keys: ["CHIE": [0x00], "D1BI": [0x00]]
  )
  #expect(!AppleSMCClient.baselineContainsLegacyReadOnlyKeys(cleanSnapshot))
  #expect(AppleSMCClient.controlledKeysForBaseline == ["CHIE", "D1BI", "D2BI", "D3BI"])
}

@Test("ChargeControlConfig.clamped 3 kademeli eğriyi sıralar, kıstırır ve eski JSON ile uyumludur")
func chargeCurveClampingAndLegacyJSONDecoding() throws {
  var config = ChargeControlConfig.defaultConfig
  config.curveStages = [
    ChargeCurveStage(stageIndex: 2, upToPercent: 98, watts: 200),
    ChargeCurveStage(stageIndex: 1, upToPercent: 5, watts: 1),
    ChargeCurveStage(stageIndex: 0, upToPercent: 18, watts: 50),
  ]
  let clamped = config.clamped()
  #expect(clamped.curveStages.count == 3)
  #expect(clamped.curveStages.map(\.stageIndex) == [0, 1, 2])
  #expect(clamped.curveStages[0].upToPercent == 15)
  #expect(clamped.curveStages[0].watts == 5)
  #expect(clamped.curveStages[1].upToPercent == 25)
  #expect(clamped.curveStages[1].watts == 50)
  #expect(clamped.curveStages[2].upToPercent == 100)
  #expect(clamped.curveStages[2].watts == 140)
  #expect(clamped.curveStages[0].upToPercent < clamped.curveStages[1].upToPercent)
  #expect(clamped.curveStages[1].upToPercent < clamped.curveStages[2].upToPercent)

  // Eşikler birbirine çok yakın olduğunda stage1 >= stage0 + 5 garanti edilmeli
  var tightConfig = ChargeControlConfig.defaultConfig
  tightConfig.curveStages = [
    ChargeCurveStage(upToPercent: 80, watts: 40),
    ChargeCurveStage(upToPercent: 81, watts: 20),
    ChargeCurveStage(upToPercent: 99, watts: 10),
  ]
  let clampedTight = tightConfig.clamped()
  #expect(clampedTight.curveStages[0].upToPercent == 80)
  #expect(clampedTight.curveStages[1].upToPercent == 85)
  #expect(clampedTight.curveStages[2].upToPercent == 100)

  // Eski stageIndex içermeyen JSON decode testi
  let legacyJSON = """
  [
    {"upToPercent": 50, "watts": 30},
    {"upToPercent": 80, "watts": 12},
    {"upToPercent": 100, "watts": 5}
  ]
  """.data(using: .utf8)!
  let decoded = try JSONDecoder().decode([ChargeCurveStage].self, from: legacyJSON)
  #expect(decoded.map(\.stageIndex) == [0, 1, 2])
  #expect(decoded.map(\.id) == [0, 1, 2])
}

@Test("HelperResponse sürüm eskimesini ve RegulationMethod aktif regülasyon durumunu doğru bildirir")
func helperVersionOutdatedAndRegulationMethodFlags() {
  let telemetry = sampleTelemetry(percent: 60, temp: 30)
  let outdated = HelperResponse(
    ok: true,
    isHelperRunning: true,
    helperVersion: "2.0.0",
    activeRegulationMethod: .powerUIMacroPulse,
    effectiveReason: "Test",
    appliedTargetWatts: 20,
    currentDutyCycleRatio: nil,
    config: .defaultConfig,
    telemetry: telemetry,
    smcDiagnostics: [],
    errorMessage: nil
  )
  #expect(outdated.isHelperOutdated)

  let current = HelperResponse(
    ok: true,
    isHelperRunning: true,
    helperVersion: HelperConstants.protocolVersion,
    activeRegulationMethod: .automaticOS,
    effectiveReason: "Test",
    appliedTargetWatts: nil,
    currentDutyCycleRatio: nil,
    config: .defaultConfig,
    telemetry: telemetry,
    smcDiagnostics: [],
    errorMessage: nil
  )
  #expect(!current.isHelperOutdated)

  let offline = HelperResponse.offline(config: .defaultConfig, telemetry: telemetry)
  #expect(!offline.isHelperOutdated)

  #expect(RegulationMethod.directSMCHardware.isActivelyRegulating)
  #expect(RegulationMethod.powerUIMacroPulse.isActivelyRegulating)
  #expect(RegulationMethod.macroPulseModulation.isActivelyRegulating)
  #expect(RegulationMethod.powerUIPassthrough.isActivelyRegulating)
  #expect(RegulationMethod.hardwareInhibit.isActivelyRegulating)
  #expect(RegulationMethod.adapterSuspend.isActivelyRegulating)
  #expect(!RegulationMethod.automaticOS.isActivelyRegulating)
  #expect(!RegulationMethod.firmwareRestricted.isActivelyRegulating)
  #expect(!RegulationMethod.helperOffline.isActivelyRegulating)
}

@Test("PowerUIBridge.shared.readState çökmeden geçerli PowerUIState döndürür")
func powerUIBridgeReadStateIsSafe() {
  let state = PowerUIBridge.shared.readState()
  #expect((1...100).contains(state.currentLimit))
  if !state.isSupported {
    #expect(!state.isEnabled)
    #expect(state.currentLimit == 100)
  }
}

private func sampleTelemetry(
  percent: Double,
  temp: Double?,
  isFullyCharged: Bool = false
) -> LivePowerTelemetry {
  LivePowerTelemetry(
    timestamp: Date(),
    isPluggedIn: true,
    isCharging: !isFullyCharged,
    isFullyCharged: isFullyCharged,
    batteryPercent: percent,
    batteryVoltage_V: 12.6,
    batteryCurrent_A: 1.5,
    batteryChargeWatts: 18.9,
    adapterRatingWatts: 30,
    adapterVoltage_V: 20.0,
    adapterCurrent_A: 1.2,
    systemInputWatts: 24.0,
    systemLoadWatts: 4.5,
    efficiencyLossWatts: 0.6,
    pmuConfiguredCurrent_mA: 1500,
    ipdWattageOverride_mW: 30_000,
    activePDOIndex: 3,
    pdoProfiles: [],
    batteryTemp_C: temp,
    notChargingReason: 0,
    slowChargingReason: 0
  )
}
