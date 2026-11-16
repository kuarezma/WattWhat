import Foundation

enum ChargeControlMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case manualWatts
  case passthroughHold
  case forceDischarge

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: return "Otomatik (macOS)"
    case .manualWatts: return "Manuel Watt"
    case .passthroughHold: return "Adaptörde Beklet (0W)"
    case .forceDischarge: return "Deşarj / Yelken"
    }
  }

  var shortTitle: String {
    switch self {
    case .automatic: return "Oto"
    case .manualWatts: return "Manuel"
    case .passthroughHold: return "Beklet"
    case .forceDischarge: return "Deşarj"
    }
  }
}

enum WattTargetScope: String, Codable, CaseIterable, Identifiable, Sendable {
  case batteryNetWatts
  case adapterInputWatts

  var id: String { rawValue }

  var title: String {
    switch self {
    case .batteryNetWatts: return "Net Pil Şarj Gücü"
    case .adapterInputWatts: return "Toplam Adaptör Çekiş Limiti"
    }
  }
}

enum MagSafeLEDMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case green
  case amber
  case off

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: return "Otomatik"
    case .green: return "Yeşil"
    case .amber: return "Turuncu"
    case .off: return "Kapalı (Gece)"
    }
  }

  var smcByte: UInt8 {
    switch self {
    case .automatic: return 0x00
    case .off: return 0x01
    case .green: return 0x03
    case .amber: return 0x04
    }
  }
}

enum PlugInDefaultBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
  case keepLastMode
  case alwaysAutomatic
  case adapterSmartProfile
  case fixedCustomWatts

  var id: String { rawValue }

  var title: String {
    switch self {
    case .keepLastMode: return "Son Seçili Modu Koru"
    case .alwaysAutomatic: return "Her Zaman macOS Otomatiğe Geç"
    case .adapterSmartProfile: return "Adaptör Gücüne Göre Akıllı Seç (%60)"
    case .fixedCustomWatts: return "Sabit Özel Watt ile Başla"
    }
  }
}

struct ChargeCurveStage: Codable, Equatable, Identifiable, Sendable {
  var stageIndex: Int
  var upToPercent: Int
  var watts: Int
  var id: Int { stageIndex }

  init(stageIndex: Int = 0, upToPercent: Int, watts: Int) {
    self.stageIndex = stageIndex
    self.upToPercent = upToPercent
    self.watts = watts
  }

  private enum CodingKeys: String, CodingKey {
    case stageIndex
    case upToPercent
    case watts
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let upToPercent = try container.decode(Int.self, forKey: .upToPercent)
    let watts = try container.decode(Int.self, forKey: .watts)
    if let stageIndex = try container.decodeIfPresent(Int.self, forKey: .stageIndex) {
      self.stageIndex = stageIndex
    } else if upToPercent <= 55 {
      self.stageIndex = 0
    } else if upToPercent <= 85 {
      self.stageIndex = 1
    } else {
      self.stageIndex = 2
    }
    self.upToPercent = upToPercent
    self.watts = watts
  }
}

struct ChargeControlConfig: Codable, Equatable, Sendable {
  var mode: ChargeControlMode
  var targetWatts: Int
  var targetScope: WattTargetScope
  var maxChargeLimitPercent: Int
  var hysteresisPercent: Int
  var topUpTo100Active: Bool
  var dischargeTargetPercent: Int
  var thermalProtectionEnabled: Bool
  var maxBatteryTempCelsius: Double
  var thermalFallbackWatts: Int
  var nightQuietModeEnabled: Bool
  var nightStartHour: Int
  var nightEndHour: Int
  var nightWatts: Int
  var nightTurnOffLED: Bool
  var customCurveEnabled: Bool
  var curveStages: [ChargeCurveStage]
  var allowDutyCycleFallback: Bool
  var plugInBehavior: PlugInDefaultBehavior
  var plugInFixedWatts: Int
  var ledMode: MagSafeLEDMode
  var lowPowerModeEnabled: Bool

  static let defaultCurve: [ChargeCurveStage] = [
    ChargeCurveStage(stageIndex: 0, upToPercent: 50, watts: 30),
    ChargeCurveStage(stageIndex: 1, upToPercent: 80, watts: 12),
    ChargeCurveStage(stageIndex: 2, upToPercent: 100, watts: 5),
  ]

  static let defaultConfig = ChargeControlConfig(
    mode: .automatic,
    targetWatts: 15,
    targetScope: .batteryNetWatts,
    maxChargeLimitPercent: 80,
    hysteresisPercent: 5,
    topUpTo100Active: false,
    dischargeTargetPercent: 60,
    thermalProtectionEnabled: true,
    maxBatteryTempCelsius: 38.0,
    thermalFallbackWatts: 8,
    nightQuietModeEnabled: false,
    nightStartHour: 23,
    nightEndHour: 7,
    nightWatts: 8,
    nightTurnOffLED: true,
    customCurveEnabled: false,
    curveStages: defaultCurve,
    allowDutyCycleFallback: true,
    plugInBehavior: .keepLastMode,
    plugInFixedWatts: 15,
    ledMode: .automatic,
    lowPowerModeEnabled: false
  )

  func clamped() -> ChargeControlConfig {
    var copy = self
    copy.targetWatts = min(max(copy.targetWatts, 5), 140)
    copy.maxChargeLimitPercent = min(max(copy.maxChargeLimitPercent, 50), 100)
    copy.hysteresisPercent = min(max(copy.hysteresisPercent, 2), 15)
    copy.dischargeTargetPercent = min(max(copy.dischargeTargetPercent, 20), 90)
    copy.maxBatteryTempCelsius = min(max(copy.maxBatteryTempCelsius, 30.0), 45.0)
    copy.thermalFallbackWatts = min(max(copy.thermalFallbackWatts, 5), 30)
    copy.nightStartHour = ((copy.nightStartHour % 24) + 24) % 24
    copy.nightEndHour = ((copy.nightEndHour % 24) + 24) % 24
    copy.nightWatts = min(max(copy.nightWatts, 5), 30)
    copy.plugInFixedWatts = min(max(copy.plugInFixedWatts, 5), 140)
    var rawStages = copy.curveStages
    if rawStages.count < 3 {
      for fallback in Self.defaultCurve where rawStages.count < 3 {
        rawStages.append(fallback)
      }
    }
    let sorted = rawStages.sorted { $0.upToPercent < $1.upToPercent }
    let s0Raw = sorted[0]
    let s1Raw = sorted[1]
    let s2Raw = sorted[2]

    let s0Percent = min(max(s0Raw.upToPercent, 15), 80)
    let s1Percent = min(max(s1Raw.upToPercent, max(s0Percent + 5, 25)), 95)

    copy.curveStages = [
      ChargeCurveStage(stageIndex: 0, upToPercent: s0Percent, watts: min(max(s0Raw.watts, 5), 140)),
      ChargeCurveStage(stageIndex: 1, upToPercent: s1Percent, watts: min(max(s1Raw.watts, 5), 140)),
      ChargeCurveStage(stageIndex: 2, upToPercent: 100, watts: min(max(s2Raw.watts, 5), 140)),
    ]
    return copy
  }
}

enum EffectivePowerCommand: Equatable, Sendable {
  case restoreAutomatic(reason: String)
  case limitWatts(watts: Int, scope: WattTargetScope, maxPercent: Int, hysteresis: Int, reason: String)
  case inhibitCharging(reason: String)
  case forceDischarge(untilPercent: Int, reason: String)

  var summaryText: String {
    switch self {
    case .restoreAutomatic(let reason):
      return reason
    case .limitWatts(let watts, let scope, _, _, let reason):
      let scopeStr = scope == .batteryNetWatts ? "Pil" : "Adaptör"
      return "\(watts)W (\(scopeStr)) — \(reason)"
    case .inhibitCharging(let reason):
      return "0W Şarj Durduruldu — \(reason)"
    case .forceDischarge(_, let reason):
      return "Deşarj Aktif — \(reason)"
    }
  }
}

struct ChargePolicyEvaluation: Equatable, Sendable {
  let command: EffectivePowerCommand
  let effectiveLED: MagSafeLEDMode
  let updatedConfig: ChargeControlConfig
  let isInHysteresisHold: Bool
}

enum ChargePolicyEvaluator {
  static let emergencyThermalCelsius: Double = 43.0
  static let minimumSafeDischargePercent: Double = 15.0

  static func isWithinHourWindow(hour: Int, startHour: Int, endHour: Int) -> Bool {
    if startHour == endHour { return false }
    if startHour < endHour {
      return hour >= startHour && hour < endHour
    }
    return hour >= startHour || hour < endHour
  }

  static func curveWatts(forPercent percent: Double, stages: [ChargeCurveStage], fallback: Int) -> Int {
    let sorted = stages.sorted { $0.upToPercent < $1.upToPercent }
    for stage in sorted where percent <= Double(stage.upToPercent) {
      return min(max(stage.watts, 5), 140)
    }
    return sorted.last.map { min(max($0.watts, 5), 140) } ?? fallback
  }

  static func configForPlugIn(
    current: ChargeControlConfig,
    adapterRatingWatts: Int
  ) -> ChargeControlConfig {
    var updated = current.clamped()
    switch updated.plugInBehavior {
    case .keepLastMode:
      return updated
    case .alwaysAutomatic:
      updated.mode = .automatic
      return updated
    case .adapterSmartProfile:
      updated.mode = .manualWatts
      let rated = adapterRatingWatts > 0 ? adapterRatingWatts : 30
      updated.targetWatts = min(max(Int((Double(rated) * 0.6).rounded()), 5), 140)
      return updated
    case .fixedCustomWatts:
      updated.mode = .manualWatts
      updated.targetWatts = min(max(updated.plugInFixedWatts, 5), 140)
      return updated
    }
  }

  static func evaluate(
    config rawConfig: ChargeControlConfig,
    telemetry: LivePowerTelemetry,
    now: Date = Date(),
    calendar: Calendar = .current,
    wasInHysteresisHold: Bool = false
  ) -> ChargePolicyEvaluation {
    var config = rawConfig.clamped()
    var hysteresisHold = wasInHysteresisHold
    var effectiveLED = config.ledMode

    let hour = calendar.component(.hour, from: now)
    let isNightActive =
      config.nightQuietModeEnabled
      && isWithinHourWindow(hour: hour, startHour: config.nightStartHour, endHour: config.nightEndHour)
    if isNightActive && config.nightTurnOffLED && effectiveLED == .automatic {
      effectiveLED = .off
    }

    // Tek seferlik %100 Top-Up hedefi dolduğunda otomatik normale dön
    if config.topUpTo100Active && (telemetry.isFullyCharged || telemetry.batteryPercent >= 99.5) {
      config.topUpTo100Active = false
    }

    // Otomatik modda macOS'a devret
    if config.mode == .automatic {
      return ChargePolicyEvaluation(
        command: .restoreAutomatic(reason: "macOS otomatik güç yönetimi devrede"),
        effectiveLED: effectiveLED,
        updatedConfig: config,
        isInHysteresisHold: false
      )
    }

    // Kritik yüksek sıcaklık güvenlik koruması (tüm aktif şarj modlarında)
    if let temp = telemetry.batteryTemp_C, temp >= emergencyThermalCelsius {
      return ChargePolicyEvaluation(
        command: .inhibitCharging(
          reason: String(format: "Acil termal koruma (%.1f °C ≥ 43.0 °C)", temp)),
        effectiveLED: effectiveLED,
        updatedConfig: config,
        isInHysteresisHold: hysteresisHold
      )
    }

    switch config.mode {
    case .automatic:
      return ChargePolicyEvaluation(
        command: .restoreAutomatic(reason: "macOS otomatik güç yönetimi devrede"),
        effectiveLED: effectiveLED,
        updatedConfig: config,
        isInHysteresisHold: false
      )

    case .passthroughHold:
      return ChargePolicyEvaluation(
        command: .inhibitCharging(reason: "Adaptörden çalışıyor, pil şarjı duraklatıldı"),
        effectiveLED: effectiveLED,
        updatedConfig: config,
        isInHysteresisHold: false
      )

    case .forceDischarge:
      if telemetry.batteryPercent <= minimumSafeDischargePercent {
        config.mode = .passthroughHold
        return ChargePolicyEvaluation(
          command: .inhibitCharging(
            reason: "Güvenlik kilidi: Pil %15 altında, deşarj durduruldu"),
          effectiveLED: effectiveLED,
          updatedConfig: config,
          isInHysteresisHold: false
        )
      }
      if telemetry.batteryPercent <= Double(config.dischargeTargetPercent) {
        config.mode = .passthroughHold
        return ChargePolicyEvaluation(
          command: .inhibitCharging(
            reason: "Hedef %\(config.dischargeTargetPercent) seviyesine inildi, adaptörde bekletiliyor"),
          effectiveLED: effectiveLED,
          updatedConfig: config,
          isInHysteresisHold: false
        )
      }
      return ChargePolicyEvaluation(
        command: .forceDischarge(
          untilPercent: config.dischargeTargetPercent,
          reason: "Hedef %\(config.dischargeTargetPercent) için pilden tüketiliyor"),
        effectiveLED: effectiveLED,
        updatedConfig: config,
        isInHysteresisHold: false
      )

    case .manualWatts:
      let effectiveLimit = config.topUpTo100Active ? 100 : config.maxChargeLimitPercent
      if effectiveLimit < 100 {
        if telemetry.batteryPercent >= Double(effectiveLimit) {
          hysteresisHold = true
        } else if hysteresisHold
          && telemetry.batteryPercent <= Double(effectiveLimit - config.hysteresisPercent)
        {
          hysteresisHold = false
        }

        if hysteresisHold {
          return ChargePolicyEvaluation(
            command: .inhibitCharging(
              reason:
                "Pil %\(effectiveLimit) sınırında bekletiliyor (yeniden başlama ≤ %\(effectiveLimit - config.hysteresisPercent))"),
            effectiveLED: effectiveLED,
            updatedConfig: config,
            isInHysteresisHold: true
          )
        }
      } else {
        hysteresisHold = false
      }

      var desiredWatts = config.targetWatts
      var reasons: [String] = []

      if config.customCurveEnabled {
        desiredWatts = curveWatts(
          forPercent: telemetry.batteryPercent,
          stages: config.curveStages,
          fallback: desiredWatts
        )
        reasons.append("Özel eğri")
      } else {
        reasons.append("Sabit hedef")
      }

      if isNightActive {
        let clampedNight = min(desiredWatts, config.nightWatts)
        if clampedNight < desiredWatts {
          desiredWatts = clampedNight
          reasons.append("Gece sessiz mod")
        }
      }

      if config.thermalProtectionEnabled, let temp = telemetry.batteryTemp_C,
        temp >= config.maxBatteryTempCelsius
      {
        let clampedThermal = min(desiredWatts, config.thermalFallbackWatts)
        if clampedThermal < desiredWatts {
          desiredWatts = clampedThermal
        }
        reasons.append(String(format: "Termal kısma (%.1f °C)", temp))
      }

      if config.topUpTo100Active {
        reasons.append("Tek seferlik %100 Top-Up")
      }

      return ChargePolicyEvaluation(
        command: .limitWatts(
          watts: min(max(desiredWatts, 5), 140),
          scope: config.targetScope,
          maxPercent: effectiveLimit,
          hysteresis: config.hysteresisPercent,
          reason: reasons.joined(separator: " · ")
        ),
        effectiveLED: effectiveLED,
        updatedConfig: config,
        isInHysteresisHold: hysteresisHold
      )
    }
  }
}
