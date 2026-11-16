import AppKit
import Foundation
import SwiftUI

struct PowerStudioActions {
  let applyConfig: @MainActor (ChargeControlConfig) -> Void
  let setAutomatic: @MainActor () -> Void
  let setLowPowerMode: @MainActor (Bool) -> Void
  let installHelper: @MainActor () -> Void
  let uninstallHelper: @MainActor () -> Void
  let refreshNow: @MainActor () -> Void
}

@MainActor
final class PowerStudioModel: ObservableObject {
  @Published var config: ChargeControlConfig
  @Published var telemetry: LivePowerTelemetry = .empty
  @Published var isHelperInstalled: Bool = false
  @Published var isHelperRunning: Bool = false
  @Published var isHelperOutdated: Bool = false
  @Published var isSystemLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
  @Published var activeRegulationMethod: RegulationMethod = .helperOffline
  @Published var effectiveReason: String = "Durum kontrol ediliyor…"
  @Published var appliedTargetWatts: Int?
  @Published var currentDutyCycleRatio: Double?
  @Published var smcDiagnostics: [SMCKeyDiagnostic] = []
  @Published var statusFeedbackMessage: String?
  @Published var isApplying: Bool = false

  let actions: PowerStudioActions

  init(initialConfig: ChargeControlConfig, actions: PowerStudioActions) {
    self.config = initialConfig
    self.actions = actions
  }
}

struct PowerStudioView: View {
  @ObservedObject var model: PowerStudioModel
  @State private var customWattInput: String = ""
  @State private var showSMCMatrix: Bool = false

  private let quickWattPresets = [5, 10, 15, 20, 30, 45, 67, 96]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        helperBanner
        livePowerFlowSection
        modeSelectorSection
        manualWattSection
        batteryCeilingSection
        automationAndCurveSection
        hardwareExtrasSection
      }
      .padding(20)
    }
    .onAppear {
      customWattInput = "\(model.config.targetWatts)"
    }
    .onReceive(model.$config) { newConfig in
      let newStr = "\(newConfig.targetWatts)"
      if customWattInput != newStr {
        customWattInput = newStr
      }
    }
  }

  // MARK: - 1. Yetkili Servis Durum Bandı

  private var helperBanner: some View {
    let isHealthy = model.isHelperRunning && !model.isHelperOutdated
    let statusColor: Color = isHealthy ? .green : .orange
    let iconName = isHealthy ? "bolt.shield.fill" : "exclamationmark.shield.fill"
    let bannerTitle: String = {
      if model.isHelperOutdated {
        return "Yetkili Güç Motoru Güncellemesi Gerekli (v\(HelperConstants.protocolVersion))"
      } else if !model.isHelperRunning {
        return "Yetkili Güç Motoru Gerekli"
      } else {
        return "Yetkili Güç Motoru Aktif"
      }
    }()

    return HStack(spacing: 12) {
      Image(systemName: iconName)
        .font(.title2)
        .foregroundStyle(statusColor)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(bannerTitle)
            .font(.headline)
          Text(model.activeRegulationMethod.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
              statusColor.opacity(0.16),
              in: Capsule()
            )
            .foregroundStyle(statusColor)
        }
        Text(model.statusFeedbackMessage ?? model.effectiveReason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(bannerTitle), \(model.activeRegulationMethod.rawValue), \(model.statusFeedbackMessage ?? model.effectiveReason)")

      Spacer()

      Button {
        model.actions.refreshNow()
      } label: {
        Label("Yenile", systemImage: "arrow.clockwise")
      }

      if model.isHelperOutdated {
        Button {
          model.actions.installHelper()
        } label: {
          Label("Güç Motorunu Güncelle ⚡️", systemImage: "arrow.triangle.2.circlepath.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
      } else if !model.isHelperRunning {
        Button {
          model.actions.installHelper()
        } label: {
          Label("Yetkili Güç Motorunu Etkinleştir ⚡️", systemImage: "lock.open.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
      } else {
        Button(role: .destructive) {
          model.actions.uninstallHelper()
        } label: {
          Text("Servisi Kaldır")
        }
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - 2. Canlı Güç Akış Şeması

  private var livePowerFlowSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Canlı Güç Akışı").font(.headline)
        Spacer()
        if let temp = model.telemetry.batteryTemp_C {
          Label(String(format: "Pil Sıcaklığı: %.1f °C", temp), systemImage: "thermometer.medium")
            .font(.caption.monospacedDigit())
            .foregroundStyle(temp >= model.config.maxBatteryTempCelsius ? .orange : .secondary)
        }
      }

      HStack(spacing: 10) {
        powerFlowCard(
          icon: "powerplug.fill",
          title: "Adaptör Girişi",
          primaryValue: model.telemetry.isPluggedIn
            ? String(format: "%.1f W", model.telemetry.systemInputWatts > 0 ? model.telemetry.systemInputWatts : Double(model.telemetry.adapterRatingWatts))
            : "Bağlı Değil",
          subtitle: model.telemetry.isPluggedIn
            ? String(
              format: "%dW Nominal · %.1fV · %.2fA",
              model.telemetry.adapterRatingWatts,
              model.telemetry.adapterVoltage_V,
              model.telemetry.adapterCurrent_A)
            : "Yalnız pil gücü",
          accent: model.telemetry.isPluggedIn ? .cyan : .secondary
        )

        Image(systemName: "arrow.right")
          .font(.title3.bold())
          .foregroundStyle(.secondary)

        powerFlowCard(
          icon: "macbook",
          title: "Sistem Yükü",
          primaryValue: String(format: "%.1f W", model.telemetry.systemLoadWatts),
          subtitle: String(format: "Verim Kaybı: %.1f W", model.telemetry.efficiencyLossWatts),
          accent: .indigo
        )

        Image(systemName: model.telemetry.isCharging ? "plus.circle.fill" : "minus.circle.fill")
          .font(.title3.bold())
          .foregroundStyle(model.telemetry.isCharging ? .green : (model.telemetry.isPluggedIn ? .teal : .yellow))

        powerFlowCard(
          icon: "battery.75",
          title: "Pil Akışı (%\(Int(model.telemetry.batteryPercent.rounded())))",
          primaryValue: batteryFlowPrimaryText,
          subtitle: String(
            format: "%.2fV · %+.2fA",
            model.telemetry.batteryVoltage_V,
            model.telemetry.batteryCurrent_A),
          accent: model.telemetry.isCharging ? .green : (model.telemetry.isPluggedIn ? .teal : .yellow)
        )
      }

      if !model.telemetry.pdoProfiles.isEmpty {
        HStack(spacing: 6) {
          Text("USB-PD Profilleri:")
            .font(.caption)
            .foregroundStyle(.secondary)
          ForEach(model.telemetry.pdoProfiles) { pdo in
            let isActive = model.telemetry.activePDOIndex == pdo.index
            Text(String(format: "%.0fV · %.0fW%@", pdo.maxVoltage_V, pdo.maxWatts, isActive ? " (Aktif)" : ""))
              .font(.caption.monospacedDigit())
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(
                isActive ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                in: Capsule()
              )
              .foregroundStyle(isActive ? Color.accentColor : .secondary)
          }
          Spacer()
        }
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }

  private var batteryFlowPrimaryText: String {
    let w = model.telemetry.batteryChargeWatts
    if model.telemetry.isCharging {
      return String(format: "+%.1f W Şarj", w)
    } else if model.telemetry.isPluggedIn && model.telemetry.batteryCurrent_A >= -0.05 {
      return "0.0 W Beklemede"
    } else {
      return String(format: "-%.1f W Deşarj", w)
    }
  }

  private func powerFlowCard(
    icon: String,
    title: String,
    primaryValue: String,
    subtitle: String,
    accent: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(title, systemImage: icon)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      Text(primaryValue)
        .font(.title3.monospacedDigit().bold())
        .foregroundStyle(accent)
      Text(subtitle)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title): \(primaryValue), \(subtitle)")
  }

  // MARK: - 3. Ana Mod Seçici

  private var modeSelectorSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Çalışma Modu").font(.headline)
      HStack(spacing: 10) {
        modeCard(
          mode: .automatic,
          icon: "cpu",
          subtitle: "Kontrolü tamamen macOS'a devret",
          color: .green
        )
        modeCard(
          mode: .manualWatts,
          icon: "slider.horizontal.3",
          subtitle: "İstediğin Watt (5W–140W) ile şarj et",
          color: .blue
        )
        modeCard(
          mode: .passthroughHold,
          icon: "shield.lefthalf.filled",
          subtitle: "Şarjı durdur (0W), fişten çalış",
          color: .teal
        )
        modeCard(
          mode: .forceDischarge,
          icon: "arrow.down.circle.fill",
          subtitle: "Fişteyken %\(model.config.dischargeTargetPercent)'a kadar pilden tüket",
          color: .orange
        )
      }
    }
  }

  private func modeCard(mode: ChargeControlMode, icon: String, subtitle: String, color: Color) -> some View {
    let selected = model.config.mode == mode
    return Button {
      if mode == .automatic {
        model.config.mode = .automatic
        model.config.topUpTo100Active = false
        model.actions.setAutomatic()
      } else {
        var updated = model.config
        updated.mode = mode
        apply(updated)
      }
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Image(systemName: icon)
            .font(.title3)
            .foregroundStyle(selected ? color : .secondary)
          Spacer()
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(color)
          }
        }
        Text(mode.title)
          .font(.subheadline.bold())
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
      .padding(10)
      .background(
        selected ? color.opacity(0.14) : Color.secondary.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 10)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(selected ? color : Color.clear, lineWidth: 1.5)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(mode.title), \(subtitle)\(selected ? ", seçili" : "")")
  }

  // MARK: - 4. Manuel Watt Özgürlük Paneli

  private var manualWattSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Manuel Watt Kontrolü").font(.headline)
        Spacer()
        Picker("Kapsam", selection: scopeBinding) {
          ForEach(WattTargetScope.allCases) { scope in
            Text(scope.title).tag(scope)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 340)
      }

      HStack(spacing: 12) {
        Button("-5W") { stepWatts(-5) }
        Button("-1W") { stepWatts(-1) }

        Slider(
          value: Binding(
            get: { Double(model.config.targetWatts) },
            set: { newVal in
              var updated = model.config
              updated.mode = .manualWatts
              updated.targetWatts = Int(newVal.rounded())
              model.config = updated
            }
          ),
          in: 5...140,
          step: 1,
          onEditingChanged: { editing in
            if !editing {
              apply(model.config)
            }
          }
        )

        Button("+1W") { stepWatts(1) }
        Button("+5W") { stepWatts(5) }

        HStack(spacing: 4) {
          TextField("Watt", text: $customWattInput)
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .multilineTextAlignment(.trailing)
            .onSubmit { applyCustomWattInput() }
          Text("W").font(.headline)
          Button("Uygula") { applyCustomWattInput() }
            .buttonStyle(.borderedProminent)
        }
      }

      HStack(spacing: 8) {
        Text("Hazır Profiller:").font(.caption).foregroundStyle(.secondary)
        ForEach(quickWattPresets, id: \.self) { watt in
          let isCurrent = model.config.mode == .manualWatts && model.config.targetWatts == watt
          Button("\(watt)W") {
            var updated = model.config
            updated.mode = .manualWatts
            updated.targetWatts = watt
            apply(updated)
          }
          .buttonStyle(.bordered)
          .tint(isCurrent ? .blue : .secondary)
        }
        Spacer()
      }

      Toggle(
        "Firmware akım anahtarını kısıtlarsa 60 sn. Akıllı Darbe Regülasyonu (CHIE) yedeğini kullan",
        isOn: Binding(
          get: { model.config.allowDutyCycleFallback },
          set: { newVal in
            var updated = model.config
            updated.allowDutyCycleFallback = newVal
            apply(updated)
          }
        )
      )
      .font(.caption)
    }
    .padding(14)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }

  private var scopeBinding: Binding<WattTargetScope> {
    Binding(
      get: { model.config.targetScope },
      set: { newScope in
        var updated = model.config
        updated.targetScope = newScope
        apply(updated)
      }
    )
  }

  private func stepWatts(_ delta: Int) {
    var updated = model.config
    updated.mode = .manualWatts
    updated.targetWatts = min(max(updated.targetWatts + delta, 5), 140)
    apply(updated)
  }

  private func applyCustomWattInput() {
    guard let parsed = Int(customWattInput.trimmingCharacters(in: .whitespaces)) else { return }
    var updated = model.config
    updated.mode = .manualWatts
    updated.targetWatts = min(max(parsed, 5), 140)
    apply(updated)
  }

  // MARK: - 5. Pil Tavanı & Deşarj Ayarları

  private var batteryCeilingSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Pil Şarj Tavanı ve Koruma").font(.headline)
        Spacer()
        Button {
          var updated = model.config
          updated.mode = .manualWatts
          updated.topUpTo100Active.toggle()
          apply(updated)
        } label: {
          Label(
            model.config.topUpTo100Active
              ? "Tek Seferlik %100 Aktif (İptal Et)" : "🚀 Bugünlük %100 Doldur (Top-Up)",
            systemImage: "battery.100.bolt"
          )
        }
        .buttonStyle(.borderedProminent)
        .tint(model.config.topUpTo100Active ? .green : .secondary)
      }

      HStack(spacing: 12) {
        Text("Maksimum Tavan: %\(model.config.maxChargeLimitPercent)")
          .font(.subheadline.monospacedDigit())
          .frame(width: 155, alignment: .leading)

        Slider(
          value: Binding(
            get: { Double(model.config.maxChargeLimitPercent) },
            set: { newVal in
              var updated = model.config
              updated.maxChargeLimitPercent = Int(newVal.rounded())
              model.config = updated
            }
          ),
          in: 50...100,
          step: 5,
          onEditingChanged: { editing in
            if !editing {
              var updated = model.config
              if updated.mode == .automatic && updated.maxChargeLimitPercent < 100 {
                updated.mode = .manualWatts
              }
              apply(updated)
            }
          }
        )

        ForEach([60, 70, 80, 90, 100], id: \.self) { limit in
          Button("%\(limit)") {
            var updated = model.config
            updated.maxChargeLimitPercent = limit
            updated.topUpTo100Active = false
            if updated.mode == .automatic && limit < 100 {
              updated.mode = .manualWatts
            }
            apply(updated)
          }
          .buttonStyle(.bordered)
          .tint(model.config.maxChargeLimitPercent == limit ? .green : .secondary)
        }
      }

      HStack(spacing: 20) {
        Stepper(
          "Histerezis (Yelken Aralığı): %\(model.config.hysteresisPercent)",
          value: Binding(
            get: { model.config.hysteresisPercent },
            set: { newVal in
              var updated = model.config
              updated.hysteresisPercent = newVal
              apply(updated)
            }
          ),
          in: 2...15
        )
        .font(.caption)

        Stepper(
          "Deşarj Hedef Yüzdesi: %\(model.config.dischargeTargetPercent)",
          value: Binding(
            get: { model.config.dischargeTargetPercent },
            set: { newVal in
              var updated = model.config
              updated.dischargeTargetPercent = newVal
              apply(updated)
            }
          ),
          in: 20...90,
          step: 5
        )
        .font(.caption)
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - 6. Akıllı Otomasyon & Özel Şarj Eğrisi

  private var automationAndCurveSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Akıllı Otomasyon & Özel Şarj Eğrisi").font(.headline)

      HStack {
        Text("Şarja Takıldığında Varsayılan Davranış:").font(.subheadline)
        Picker("", selection: Binding(
          get: { model.config.plugInBehavior },
          set: { newBehavior in
            var updated = model.config
            updated.plugInBehavior = newBehavior
            apply(updated)
          }
        )) {
          ForEach(PlugInDefaultBehavior.allCases) { behavior in
            Text(behavior.title).tag(behavior)
          }
        }
        .frame(maxWidth: 320)
        .accessibilityLabel("Şarja takıldığında varsayılan davranış")

        if model.config.plugInBehavior == .fixedCustomWatts {
          Stepper(
            "\(model.config.plugInFixedWatts) W",
            value: Binding(
              get: { model.config.plugInFixedWatts },
              set: { newVal in
                var updated = model.config
                updated.plugInFixedWatts = newVal
                apply(updated)
              }
            ),
            in: 5...140,
            step: 5
          )
          .frame(width: 120)
        }
        Spacer()
      }

      Divider()

      Toggle(
        "Pil Yüzdesine Göre 3 Kademeli Özel Şarj Eğrisini Kullan",
        isOn: Binding(
          get: { model.config.customCurveEnabled },
          set: { newVal in
            var updated = model.config
            updated.customCurveEnabled = newVal
            if newVal { updated.mode = .manualWatts }
            apply(updated)
          }
        )
      )
      .font(.subheadline.weight(.medium))

      if model.config.customCurveEnabled {
        HStack(spacing: 12) {
          ForEach(model.config.curveStages) { stage in
            let prevBound: Int = {
              guard let idx = model.config.curveStages.firstIndex(where: { $0.stageIndex == stage.stageIndex }),
                idx > 0
              else { return 0 }
              return model.config.curveStages[idx - 1].upToPercent
            }()
            let upperBound = stage.stageIndex == 2 ? 100 : stage.upToPercent
            VStack(alignment: .leading, spacing: 6) {
              Text("%\(prevBound) – %\(upperBound) Arası")
                .font(.caption.bold())
              if stage.stageIndex == 0 || stage.stageIndex == 1 {
                Stepper(
                  "Tavan: %\(stage.upToPercent)",
                  value: Binding(
                    get: {
                      model.config.curveStages.first(where: { $0.stageIndex == stage.stageIndex })?.upToPercent
                        ?? stage.upToPercent
                    },
                    set: { newPercent in
                      var updated = model.config
                      if let idx = updated.curveStages.firstIndex(where: { $0.stageIndex == stage.stageIndex }) {
                        updated.curveStages[idx].upToPercent = newPercent
                        apply(updated.clamped())
                      }
                    }
                  ),
                  in: stage.stageIndex == 0 ? 15...75 : 25...95,
                  step: 5
                )
                .font(.caption.monospacedDigit())
              } else {
                Text("Tavan: %100 (Sabit)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              Stepper(
                "\(stage.watts) W",
                value: Binding(
                  get: {
                    model.config.curveStages.first(where: { $0.stageIndex == stage.stageIndex })?.watts
                      ?? stage.watts
                  },
                  set: { newWatts in
                    var updated = model.config
                    if let idx = updated.curveStages.firstIndex(where: { $0.stageIndex == stage.stageIndex }) {
                      updated.curveStages[idx].watts = newWatts
                      apply(updated.clamped())
                    }
                  }
                ),
                in: 5...140,
                step: 1
              )
              .font(.caption.monospacedDigit())
            }
            .padding(8)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
          }
          Spacer()
        }
      }

      Divider()

      HStack(spacing: 16) {
        Toggle(
          "Otomatik Termal Kısma",
          isOn: Binding(
            get: { model.config.thermalProtectionEnabled },
            set: { newVal in
              var updated = model.config
              updated.thermalProtectionEnabled = newVal
              apply(updated)
            }
          )
        )
        Stepper(
          String(format: "Eşik: %.0f °C", model.config.maxBatteryTempCelsius),
          value: Binding(
            get: { model.config.maxBatteryTempCelsius },
            set: { newVal in
              var updated = model.config
              updated.maxBatteryTempCelsius = newVal
              apply(updated)
            }
          ),
          in: 30...45,
          step: 1
        )
        .font(.caption)
        Stepper(
          "Düşüş: \(model.config.thermalFallbackWatts) W",
          value: Binding(
            get: { model.config.thermalFallbackWatts },
            set: { newVal in
              var updated = model.config
              updated.thermalFallbackWatts = newVal
              apply(updated)
            }
          ),
          in: 5...30,
          step: 1
        )
        .font(.caption)
        Spacer()
      }

      HStack(spacing: 14) {
        Toggle(
          "Gece Sessiz & Soğuk Şarj",
          isOn: Binding(
            get: { model.config.nightQuietModeEnabled },
            set: { newVal in
              var updated = model.config
              updated.nightQuietModeEnabled = newVal
              apply(updated)
            }
          )
        )
        Stepper(
          String(format: "%02d:00 Başla", model.config.nightStartHour),
          value: Binding(
            get: { model.config.nightStartHour },
            set: { newVal in
              var updated = model.config
              updated.nightStartHour = newVal
              apply(updated)
            }
          ),
          in: 0...23
        )
        .font(.caption)
        Stepper(
          String(format: "%02d:00 Bitir", model.config.nightEndHour),
          value: Binding(
            get: { model.config.nightEndHour },
            set: { newVal in
              var updated = model.config
              updated.nightEndHour = newVal
              apply(updated)
            }
          ),
          in: 0...23
        )
        .font(.caption)
        Stepper(
          "Gece: \(model.config.nightWatts) W",
          value: Binding(
            get: { model.config.nightWatts },
            set: { newVal in
              var updated = model.config
              updated.nightWatts = newVal
              apply(updated)
            }
          ),
          in: 5...30
        )
        .font(.caption)
        Toggle(
          "LED Kapat",
          isOn: Binding(
            get: { model.config.nightTurnOffLED },
            set: { newVal in
              var updated = model.config
              updated.nightTurnOffLED = newVal
              apply(updated)
            }
          )
        )
        .font(.caption)
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - 7. Donanım Ekstraları & SMC Tanılama

  private var hardwareExtrasSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 16) {
        Text("Donanım Kontrolleri").font(.headline)
        Spacer()
        HStack(spacing: 6) {
          Text("MagSafe LED:").font(.subheadline)
          Picker("", selection: Binding(
            get: { model.config.ledMode },
            set: { newLED in
              var updated = model.config
              updated.ledMode = newLED
              apply(updated)
            }
          )) {
            ForEach(MagSafeLEDMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: 280)
          .accessibilityLabel("MagSafe LED modu")
        }

        Toggle(
          "Düşük Güç Modu",
          isOn: Binding(
            get: { model.isSystemLowPowerMode },
            set: { model.actions.setLowPowerMode($0) }
          )
        )
      }

      DisclosureGroup("Canlı AppleSMC & Donanım Anahtar Matrisi (\(model.smcDiagnostics.count) anahtar)", isExpanded: $showSMCMatrix) {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Anahtar").frame(width: 65, alignment: .leading)
            Text("Tip").frame(width: 45, alignment: .leading)
            Text("Boyut").frame(width: 45, alignment: .leading)
            Text("Hex Değer").frame(width: 140, alignment: .leading)
            Text("Sayısal").frame(width: 110, alignment: .leading)
            Text("Son Yazma Durumu").frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.caption.bold())
          .foregroundStyle(.secondary)
          Divider()
          ForEach(model.smcDiagnostics) { item in
            HStack {
              Text(item.key).font(.caption.monospaced().bold()).frame(width: 65, alignment: .leading)
              Text(item.dataType).font(.caption.monospaced()).frame(width: 45, alignment: .leading)
              Text("\(item.dataSize)B").font(.caption.monospacedDigit()).frame(width: 45, alignment: .leading)
              Text(item.currentHex).font(.caption.monospaced()).lineLimit(1).frame(width: 140, alignment: .leading)
              Text(item.numericSummary).font(.caption.monospacedDigit()).frame(width: 110, alignment: .leading)
              Text(item.lastWriteResult ?? (item.isWritableFlag ? "Yazılabilir" : "Salt-okunur"))
                .font(.caption)
                .foregroundStyle(item.lastWriteResult == "OK" ? .green : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .padding(.top, 8)
      }
      .font(.subheadline.weight(.medium))
    }
    .padding(14)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }

  private func apply(_ config: ChargeControlConfig) {
    model.config = config
    model.actions.applyConfig(config)
  }
}
