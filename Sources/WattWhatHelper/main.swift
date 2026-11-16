import Darwin
import Foundation
import Security

#if canImport(WattWhatCore)
import WattWhatCore
#endif

final class PowerControlEngine: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.kuarezma.wattwhat.helper.engine")
  private var config: ChargeControlConfig
  private var baseline: SMCBaselineSnapshot?
  private var initialPowerUIState: PowerUIState
  private var hasDirtySMCChanges = false
  private var hasDirtyPowerUIChanges = false
  private var lastAppliedPowerUILimit: Int?
  private var lastAppliedPowerUITopUp = false
  private var isInHysteresisHold = false
  private var lastAppliedLED: MagSafeLEDMode?
  private var lastWriteResults: [String: String] = [:]
  private var activeMethod: RegulationMethod = .automaticOS
  private var effectiveReason: String = "macOS otomatik güç yönetimi devrede"
  private var appliedTargetWatts: Int?
  private var currentDutyRatio: Double?

  // Kapalı çevrim geri besleme ve makro-darbe zamanlayıcı durumu
  private var lastLimitTargetWatts: Int?
  private var observedActiveChargeWatts: Double?
  private var pulseWindowStart: Date = Date()
  private var holdPhaseStartDate: Date?
  private var holdFallbackActiveThisPhase = false

  private var timer: DispatchSourceTimer?

  init() {
    self.config = Self.loadConfigFromDisk()
    self.initialPowerUIState = PowerUIBridge.shared.readState()
    let loadedBaseline = Self.loadBaselineFromDisk()
    if let loadedBaseline, AppleSMCClient.baselineContainsLegacyReadOnlyKeys(loadedBaseline) {
      if let client = try? AppleSMCClient() {
        let captured = client.captureBaseline()
        self.baseline = captured
        Self.saveBaselineToDisk(captured)
      } else {
        self.baseline = nil
      }
    } else {
      self.baseline = loadedBaseline
    }
    if self.config.mode != .automatic {
      self.hasDirtySMCChanges = true
    }
  }

  func startLoop() {
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .now(), repeating: .seconds(2))
    source.setEventHandler { [weak self] in
      self?.tick()
    }
    self.timer = source
    source.resume()
  }

  func restoreBaselineOnShutdown() {
    queue.sync {
      if hasDirtySMCChanges || (lastAppliedLED != nil && lastAppliedLED != .automatic) {
        if let client = try? AppleSMCClient() {
          if let baseline {
            lastWriteResults = client.restoreBaseline(baseline)
          }
          _ = setAdapterSuspend(client: client, suspend: false)
          _ = recordWrite(client: client, key: "ACLC", bytes: [0x00])
        }
        hasDirtySMCChanges = false
        lastAppliedLED = .automatic
      }
      if hasDirtyPowerUIChanges {
        restoreInitialPowerUIState()
      }
    }
  }

  func handleRequest(_ request: HelperRequest) -> HelperResponse {
    queue.sync {
      switch request.command {
      case .status:
        let telemetry = PowerTelemetryReader.read()
        let diags = AppleSMCClient.probeReadableChargerKeys(lastWriteResults: lastWriteResults)
        return makeResponse(ok: true, telemetry: telemetry, diagnostics: diags, error: nil)

      case .probeHardware:
        let telemetry = PowerTelemetryReader.read()
        let diags = AppleSMCClient.probeReadableChargerKeys(lastWriteResults: lastWriteResults)
        return makeResponse(ok: true, telemetry: telemetry, diagnostics: diags, error: nil)

      case .applyConfig:
        if let newConfig = request.config {
          let clamped = newConfig.clamped()
          if clamped.targetWatts != config.targetWatts || clamped.mode != config.mode
            || clamped.targetScope != config.targetScope
          {
            lastLimitTargetWatts = nil
            holdPhaseStartDate = nil
            holdFallbackActiveThisPhase = false
            if clamped.targetScope != config.targetScope || clamped.mode != config.mode {
              observedActiveChargeWatts = nil
            }
            if clamped.mode != config.mode {
              pulseWindowStart = Date()
            }
          }
          config = clamped
          Self.saveConfigToDisk(config)
          tickLocked()
        }
        let telemetry = PowerTelemetryReader.read()
        let diags = AppleSMCClient.probeReadableChargerKeys(lastWriteResults: lastWriteResults)
        return makeResponse(ok: true, telemetry: telemetry, diagnostics: diags, error: nil)

      case .setAutomatic:
        config.mode = .automatic
        config.topUpTo100Active = false
        lastLimitTargetWatts = nil
        observedActiveChargeWatts = nil
        holdPhaseStartDate = nil
        holdFallbackActiveThisPhase = false
        Self.saveConfigToDisk(config)
        tickLocked()
        let telemetry = PowerTelemetryReader.read()
        let diags = AppleSMCClient.probeReadableChargerKeys(lastWriteResults: lastWriteResults)
        return makeResponse(ok: true, telemetry: telemetry, diagnostics: diags, error: nil)

      case .setLowPowerMode:
        let target = request.lowPowerMode ?? false
        let pmsetOK = applySystemLowPowerMode(enabled: target)
        config.lowPowerModeEnabled = target
        Self.saveConfigToDisk(config)
        let telemetry = PowerTelemetryReader.read()
        let diags = AppleSMCClient.probeReadableChargerKeys(lastWriteResults: lastWriteResults)
        return makeResponse(
          ok: pmsetOK,
          telemetry: telemetry,
          diagnostics: diags,
          error: pmsetOK ? nil : "pmset lowpowermode komutu uygulanamadı."
        )

      case .uninstallCleanup:
        config.mode = .automatic
        config.ledMode = .automatic
        config.topUpTo100Active = false
        Self.saveConfigToDisk(config)
        if let client = try? AppleSMCClient() {
          if let baseline {
            lastWriteResults = client.restoreBaseline(baseline)
          }
          _ = setAdapterSuspend(client: client, suspend: false)
          _ = recordWrite(client: client, key: "ACLC", bytes: [0x00])
        }
        _ = PowerUIBridge.shared.disableChargeLimit()
        hasDirtySMCChanges = false
        hasDirtyPowerUIChanges = false
        lastAppliedPowerUILimit = nil
        lastAppliedPowerUITopUp = false
        lastAppliedLED = .automatic
        activeMethod = .automaticOS
        effectiveReason = "macOS otomatik güç yönetimi devrede"
        appliedTargetWatts = nil
        currentDutyRatio = nil
        let telemetry = PowerTelemetryReader.read()
        return makeResponse(ok: true, telemetry: telemetry, diagnostics: [], error: nil)
      }
    }
  }

  private func tick() {
    tickLocked()
  }

  private func tickLocked() {
    let now = Date()
    let telemetry = PowerTelemetryReader.read(now: now)

    if !telemetry.isPluggedIn {
      observedActiveChargeWatts = nil
    }

    let evaluation = ChargePolicyEvaluator.evaluate(
      config: config,
      telemetry: telemetry,
      now: now,
      wasInHysteresisHold: isInHysteresisHold
    )
    isInHysteresisHold = evaluation.isInHysteresisHold

    if evaluation.updatedConfig != config {
      config = evaluation.updatedConfig
      Self.saveConfigToDisk(config)
    }

    guard let client = try? AppleSMCClient() else {
      activeMethod = .firmwareRestricted
      effectiveReason = "AppleSMC bağlantısı açılamadı."
      return
    }

    ensureBaselineCaptured(client: client)

    switch evaluation.command {
    case .restoreAutomatic(let reason):
      if hasDirtySMCChanges {
        if let baseline {
          lastWriteResults = client.restoreBaseline(baseline)
        }
        _ = setAdapterSuspend(client: client, suspend: false)
        _ = recordWrite(client: client, key: "ACLC", bytes: [0x00])
        hasDirtySMCChanges = false
        lastAppliedLED = .automatic
      }
      if hasDirtyPowerUIChanges {
        restoreInitialPowerUIState()
      }
      activeMethod = .automaticOS
      effectiveReason = reason
      appliedTargetWatts = nil
      currentDutyRatio = nil
      lastLimitTargetWatts = nil
      observedActiveChargeWatts = nil
      holdPhaseStartDate = nil
      holdFallbackActiveThisPhase = false

    case .inhibitCharging(let reason):
      ensureBaselineCaptured(client: client)
      _ = setAdapterSuspend(client: client, suspend: false)
      lastLimitTargetWatts = nil
      holdPhaseStartDate = nil
      holdFallbackActiveThisPhase = false

      if PowerUIBridge.shared.isSupported {
        let holdRes = applyPowerUIHoldCached(
          percent: telemetry.batteryPercent,
          isCharging: telemetry.isCharging
        )
        if case .success = holdRes {
          activeMethod = .powerUIPassthrough
          effectiveReason = reason
        } else if telemetry.batteryPercent >= 20 {
          hasDirtySMCChanges = true
          let suspendOK = setAdapterSuspend(client: client, suspend: true)
          activeMethod = suspendOK ? .adapterSuspend : .firmwareRestricted
          effectiveReason =
            suspendOK
            ? reason
            : "\(reason) (Uyarı: PowerUI ve firmware şarj durdurmayı reddetti)"
        } else {
          activeMethod = .firmwareRestricted
          effectiveReason = "\(reason) (Uyarı: PowerUI şarj durdurmayı reddetti)"
        }
      } else {
        let inhibitOK = setChargingInhibit(client: client, inhibit: true)
        if inhibitOK {
          hasDirtySMCChanges = true
          activeMethod = .hardwareInhibit
          effectiveReason = reason
        } else if telemetry.batteryPercent >= 20 {
          hasDirtySMCChanges = true
          let suspendOK = setAdapterSuspend(client: client, suspend: true)
          activeMethod = suspendOK ? .adapterSuspend : .firmwareRestricted
          effectiveReason =
            suspendOK
            ? reason
            : "\(reason) (Uyarı: Firmware şarj durdurma anahtarını reddetti)"
        } else {
          activeMethod = .firmwareRestricted
          effectiveReason = "\(reason) (Uyarı: Firmware şarj durdurma anahtarını reddetti)"
        }
      }
      appliedTargetWatts = 0
      currentDutyRatio = 0.0

    case .forceDischarge(let untilPercent, let reason):
      ensureBaselineCaptured(client: client)
      hasDirtySMCChanges = true
      let suspendOK = setAdapterSuspend(client: client, suspend: true)
      activeMethod = suspendOK ? .adapterSuspend : .firmwareRestricted
      effectiveReason =
        suspendOK
        ? "\(reason) (Hedef: %\(untilPercent))"
        : "Firmware adaptör kesme anahtarını (CHIE) kabul etmedi"
      appliedTargetWatts = 0
      currentDutyRatio = nil
      lastLimitTargetWatts = nil
      holdPhaseStartDate = nil
      holdFallbackActiveThisPhase = false

    case .limitWatts(let watts, let scope, let maxPercent, _, let reason):
      ensureBaselineCaptured(client: client)

      let measuredWatts =
        scope == .batteryNetWatts
        ? telemetry.batteryChargeWatts
        : max(telemetry.systemInputWatts, telemetry.batteryChargeWatts + telemetry.systemLoadWatts)
      let fallbackEstimate = max(
        Double(telemetry.adapterRatingWatts > 0 ? telemetry.adapterRatingWatts : 30)
          - telemetry.systemLoadWatts,
        18.0
      )
      let currentActiveWatts = observedActiveChargeWatts ?? fallbackEstimate

      if Double(watts) >= currentActiveWatts * 0.95 {
        _ = setAdapterSuspend(client: client, suspend: false)
        holdPhaseStartDate = nil
        holdFallbackActiveThisPhase = false

        if telemetry.isPluggedIn && telemetry.isCharging && measuredWatts > 2.0 {
          observedActiveChargeWatts = 0.7 * currentActiveWatts + 0.3 * measuredWatts
        }

        let targetLimit = config.topUpTo100Active ? 100 : maxPercent
        let limitRes = applyPowerUILimitCached(targetLimit, topUp: config.topUpTo100Active)
        let displayMax = Int((observedActiveChargeWatts ?? currentActiveWatts).rounded())

        if case .success = limitRes {
          activeMethod = .powerUIMacroPulse
          effectiveReason = "\(reason) · Tam Kapasite (Maks ~\(displayMax)W)"
        } else {
          activeMethod = .firmwareRestricted
          effectiveReason = "\(reason) · PowerUI şarj limiti uygulanamadı"
        }
        currentDutyRatio = 1.0
        appliedTargetWatts = watts
      } else {
        let windowSeconds = 60.0
        let duty = min(max(Double(watts) / max(currentActiveWatts, 5.0), 0.10), 0.92)
        let onSeconds = max(6.0, min(windowSeconds - 6.0, (windowSeconds * duty).rounded()))

        if lastLimitTargetWatts != watts {
          lastLimitTargetWatts = watts
          pulseWindowStart = now
          holdPhaseStartDate = nil
          holdFallbackActiveThisPhase = false
        }

        var phase = now.timeIntervalSince(pulseWindowStart)
        if phase >= windowSeconds || phase < 0 {
          pulseWindowStart = now
          phase = 0
          holdPhaseStartDate = nil
          holdFallbackActiveThisPhase = false
        }

        if phase < onSeconds {
          holdPhaseStartDate = nil
          holdFallbackActiveThisPhase = false
          _ = setAdapterSuspend(client: client, suspend: false)

          if telemetry.isPluggedIn && telemetry.isCharging && measuredWatts > 2.0 {
            observedActiveChargeWatts = 0.7 * currentActiveWatts + 0.3 * measuredWatts
          }

          let targetLimit = config.topUpTo100Active ? 100 : maxPercent
          let limitRes = applyPowerUILimitCached(targetLimit, topUp: config.topUpTo100Active)
          if case .success = limitRes {
            activeMethod = .powerUIMacroPulse
          } else if config.allowDutyCycleFallback && telemetry.batteryPercent >= 20 {
            activeMethod = .macroPulseModulation
          } else {
            activeMethod = .firmwareRestricted
          }
        } else {
          if holdPhaseStartDate == nil {
            holdPhaseStartDate = now
          }

          if holdFallbackActiveThisPhase {
            hasDirtySMCChanges = true
            let suspendOK = setAdapterSuspend(client: client, suspend: true)
            activeMethod = suspendOK ? .macroPulseModulation : .firmwareRestricted
          } else {
            _ = setAdapterSuspend(client: client, suspend: false)
            let holdRes = applyPowerUIHoldCached(
              percent: telemetry.batteryPercent,
              isCharging: telemetry.isCharging
            )
            let holdFailed: Bool
            if case .failure = holdRes {
              holdFailed = true
            } else {
              holdFailed = false
            }

            let holdElapsed = now.timeIntervalSince(holdPhaseStartDate ?? now)
            let shouldUseCHIE =
              (holdFailed || (holdElapsed >= 6.0 && telemetry.isCharging && telemetry.batteryChargeWatts > 2.0))
              && config.allowDutyCycleFallback
              && telemetry.batteryPercent >= 20

            if shouldUseCHIE {
              holdFallbackActiveThisPhase = true
              hasDirtySMCChanges = true
              let suspendOK = setAdapterSuspend(client: client, suspend: true)
              activeMethod = suspendOK ? .macroPulseModulation : .firmwareRestricted
            } else if holdFailed {
              activeMethod = .firmwareRestricted
            } else {
              activeMethod = .powerUIMacroPulse
            }
          }
        }

        currentDutyRatio = duty
        appliedTargetWatts = watts
        effectiveReason =
          "\(reason) · Ortalama \(watts)W (%100 sıfır-deşarj darbe %\(Int((duty * 100).rounded())), \(Int(onSeconds))sn şarj / \(Int(windowSeconds - onSeconds))sn 0W passthrough)"
      }
    }

    // LED kontrolü (yalnız değiştiğinde veya aktif müdahale sırasında)
    applyLEDIfNeeded(client: client, mode: evaluation.effectiveLED)
  }

  private func restoreInitialPowerUIState() {
    if initialPowerUIState.isEnabled && initialPowerUIState.currentLimit < 100 {
      _ = PowerUIBridge.shared.setExactChargeLimit(initialPowerUIState.currentLimit)
    } else {
      _ = PowerUIBridge.shared.disableChargeLimit()
    }
    hasDirtyPowerUIChanges = false
    lastAppliedPowerUILimit = nil
    lastAppliedPowerUITopUp = false
  }

  private func applyPowerUILimitCached(_ limit: Int, topUp: Bool) -> Result<Void, Error> {
    guard PowerUIBridge.shared.isSupported else {
      return .failure(
        NSError(
          domain: "WattWhatPowerUI",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: "PowerUI şarj limiti bu cihazda desteklenmiyor."]
        ))
    }
    let targetLimit = topUp ? 100 : min(max(limit, 1), 100)
    if lastAppliedPowerUILimit == targetLimit && lastAppliedPowerUITopUp == topUp {
      return .success(())
    }
    let result: Result<Void, Error>
    if topUp {
      result = PowerUIBridge.shared.enableTemporaryTopUpTo100()
    } else if targetLimit >= 100 {
      result = PowerUIBridge.shared.disableChargeLimit()
    } else {
      result = PowerUIBridge.shared.setExactChargeLimit(targetLimit)
    }
    if case .success = result {
      lastAppliedPowerUILimit = targetLimit
      lastAppliedPowerUITopUp = topUp
      hasDirtyPowerUIChanges = true
    }
    return result
  }

  private func applyPowerUIHoldCached(percent: Double, isCharging: Bool) -> Result<Void, Error> {
    guard PowerUIBridge.shared.isSupported else {
      return .failure(
        NSError(
          domain: "WattWhatPowerUI",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: "PowerUI şarj limiti bu cihazda desteklenmiyor."]
        ))
    }
    let holdTarget = min(max(Int(percent.rounded(.down)), 10), 99)
    if lastAppliedPowerUILimit == holdTarget && !lastAppliedPowerUITopUp && !isCharging {
      return .success(())
    }
    let result = PowerUIBridge.shared.holdChargingNow(currentBatteryPercent: percent)
    if case .success = result {
      lastAppliedPowerUILimit = holdTarget
      lastAppliedPowerUITopUp = false
      hasDirtyPowerUIChanges = true
    }
    return result
  }

  private func ensureBaselineCaptured(client: AppleSMCClient) {
    if let existing = baseline, AppleSMCClient.baselineContainsLegacyReadOnlyKeys(existing) {
      baseline = nil
    }
    if baseline == nil {
      let captured = client.captureBaseline()
      baseline = captured
      Self.saveBaselineToDisk(captured)
    }
  }

  private func applyLEDIfNeeded(client: AppleSMCClient, mode: MagSafeLEDMode) {
    if mode == .automatic {
      if lastAppliedLED != nil && lastAppliedLED != .automatic {
        recordWrite(client: client, key: "ACLC", bytes: [0x00])
      }
      lastAppliedLED = .automatic
      return
    }
    recordWrite(client: client, key: "ACLC", bytes: [mode.smcByte])
    lastAppliedLED = mode
  }

  @discardableResult
  private func recordWrite(client: AppleSMCClient, key: String, bytes: [UInt8]) -> Bool {
    do {
      let info = try client.keyInfo(for: key)
      guard (info.attributes & 0x40) != 0 else {
        lastWriteResults[key] = "Atlandı (salt-okunur)"
        return false
      }
      try client.writeKey(key, bytes: bytes)
      lastWriteResults[key] = "OK"
      return true
    } catch {
      lastWriteResults[key] = error.localizedDescription
      return false
    }
  }

  private func setChargingInhibit(client: AppleSMCClient, inhibit: Bool) -> Bool {
    var anyOK = false
    if recordWrite(client: client, key: "CHIL", bytes: [inhibit ? 0x01 : 0x00]) { anyOK = true }
    if recordWrite(client: client, key: "CHCE", bytes: [inhibit ? 0x00 : 0x01]) { anyOK = true }
    // Eski M1/M2 anahtarları sadece dataSize > 0 ise denenir
    for legacyKey in ["CH0B", "CH0C", "CHTE"] {
      if let info = try? client.keyInfo(for: legacyKey), info.dataSize == 1 {
        let val: UInt8 = inhibit ? (legacyKey == "CHTE" ? 0x01 : 0x02) : 0x00
        if recordWrite(client: client, key: legacyKey, bytes: [val]) { anyOK = true }
      }
    }
    return anyOK
  }

  private func setAdapterSuspend(client: AppleSMCClient, suspend: Bool) -> Bool {
    recordWrite(client: client, key: "CHIE", bytes: [suspend ? 0x08 : 0x00])
  }

  private func applySystemLowPowerMode(enabled: Bool) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = ["-a", "lowpowermode", enabled ? "1" : "0"]
    do {
      try task.run()
      task.waitUntilExit()
      return task.terminationStatus == 0
    } catch {
      return false
    }
  }

  func makeErrorResponse(error: String) -> HelperResponse {
    queue.sync {
      let telemetry = PowerTelemetryReader.read()
      return HelperResponse(
        ok: false,
        isHelperRunning: true,
        helperVersion: HelperConstants.protocolVersion,
        activeRegulationMethod: activeMethod,
        effectiveReason: error,
        appliedTargetWatts: appliedTargetWatts,
        currentDutyCycleRatio: currentDutyRatio,
        config: config,
        telemetry: telemetry,
        smcDiagnostics: [],
        errorMessage: error
      )
    }
  }

  private func makeResponse(
    ok: Bool,
    telemetry: LivePowerTelemetry,
    diagnostics: [SMCKeyDiagnostic],
    error: String?
  ) -> HelperResponse {
    HelperResponse(
      ok: ok,
      isHelperRunning: true,
      helperVersion: HelperConstants.protocolVersion,
      activeRegulationMethod: activeMethod,
      effectiveReason: effectiveReason,
      appliedTargetWatts: appliedTargetWatts,
      currentDutyCycleRatio: currentDutyRatio,
      config: config,
      telemetry: telemetry,
      smcDiagnostics: diagnostics,
      errorMessage: error
    )
  }

  private static func loadConfigFromDisk() -> ChargeControlConfig {
    let url = URL(fileURLWithPath: HelperConstants.configFilePath)
    guard let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode(ChargeControlConfig.self, from: data)
    else { return .defaultConfig }
    return decoded.clamped()
  }

  private static func saveConfigToDisk(_ config: ChargeControlConfig) {
    let url = URL(fileURLWithPath: HelperConstants.configFilePath)
    guard let data = try? JSONEncoder().encode(config.clamped()) else { return }
    try? data.write(to: url, options: .atomic)
  }

  private static func loadBaselineFromDisk() -> SMCBaselineSnapshot? {
    let url = URL(fileURLWithPath: HelperConstants.baselineFilePath)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(SMCBaselineSnapshot.self, from: data)
  }

  private static func saveBaselineToDisk(_ snapshot: SMCBaselineSnapshot) {
    let url = URL(fileURLWithPath: HelperConstants.baselineFilePath)
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    try? data.write(to: url, options: .atomic)
  }
}

final class SocketServer {
  private let engine: PowerControlEngine
  private var listenFD: Int32 = -1

  init(engine: PowerControlEngine) {
    self.engine = engine
  }

  func run() -> Never {
    unlink(HelperConstants.socketPath)
    listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenFD >= 0 else {
      fputs("Socket oluşturulamadı: \(errno)\n", stderr)
      exit(1)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(HelperConstants.socketPath.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
      for (i, byte) in pathBytes.enumerated() {
        dest[i] = UInt8(bitPattern: byte)
      }
    }

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bindRes = withUnsafePointer(to: &addr) { ptr -> Int32 in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.bind(listenFD, sockPtr, addrLen)
      }
    }
    guard bindRes == 0 else {
      fputs("Socket bind başarısız: \(errno)\n", stderr)
      exit(1)
    }
    chmod(HelperConstants.socketPath, 0o666)
    guard Darwin.listen(listenFD, 16) == 0 else {
      fputs("Socket listen başarısız: \(errno)\n", stderr)
      exit(1)
    }

    while true {
      let clientFD = Darwin.accept(listenFD, nil, nil)
      if clientFD < 0 {
        if errno == EINTR { continue }
        continue
      }
      handleClient(clientFD)
      close(clientFD)
    }
  }

  private static let maxRequestBytes = 65_536

  private func handleClient(_ clientFD: Int32) {
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(clientFD, &peerUID, &peerGID) == 0 else {
      return
    }
    if peerUID != 0 {
      var consoleStat = stat()
      guard stat("/dev/console", &consoleStat) == 0, peerUID == consoleStat.st_uid else {
        return
      }
    }

    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var exceededLimit = false
    while true {
      let count = Darwin.recv(clientFD, &buffer, buffer.count, 0)
      if count <= 0 { break }
      if received.count + count > Self.maxRequestBytes {
        exceededLimit = true
        break
      }
      received.append(buffer, count: count)
      if buffer[0..<count].contains(0x0A) { break }
    }
    if exceededLimit {
      sendResponse(
        engine.makeErrorResponse(error: "İstek boyutu izin verilen 64 KB sınırını aşıyor."),
        to: clientFD
      )
      return
    }
    if let newline = received.firstIndex(of: 0x0A) {
      received = received[..<newline]
    }
    guard !received.isEmpty,
      let request = try? JSONDecoder().decode(HelperRequest.self, from: received)
    else { return }

    if requiresTrustedPeer(for: request.command),
      let authError = verifyTrustedPeer(clientFD: clientFD, peerUID: peerUID)
    {
      sendResponse(engine.makeErrorResponse(error: authError), to: clientFD)
      return
    }

    let response = engine.handleRequest(request)
    sendResponse(response, to: clientFD)
  }

  private func sendResponse(_ response: HelperResponse, to clientFD: Int32) {
    if var outData = try? JSONEncoder().encode(response) {
      outData.append(0x0A)
      outData.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < outData.count {
          let w = Darwin.send(clientFD, base.advanced(by: sent), outData.count - sent, 0)
          if w <= 0 { break }
          sent += w
        }
      }
    }
  }

  private func requiresTrustedPeer(for command: HelperCommand) -> Bool {
    switch command {
    case .applyConfig, .setAutomatic, .setLowPowerMode, .uninstallCleanup:
      return true
    case .status, .probeHardware:
      return false
    }
  }

  private func verifyTrustedPeer(clientFD: Int32, peerUID: uid_t) -> String? {
    if peerUID == 0 {
      return nil
    }

    var peerPID: pid_t = 0
    var pidLen = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(clientFD, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &pidLen) == 0,
      peerPID > 0
    else {
      return "Yetkisiz istemci: Süreç kimliği (PID) doğrulanamadı."
    }

    var pathBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let pathLen = pathBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
      guard let base = buffer.baseAddress else { return 0 }
      return proc_pidpath(peerPID, base, UInt32(buffer.count))
    }
    guard pathLen > 0 else {
      return "Yetkisiz istemci: Çalıştırılabilir dosya yolu okunamadı."
    }

    let rawPath = String(decoding: pathBuffer.prefix(Int(pathLen)), as: UTF8.self)
    let resolvedPath = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path

    let trustedAppPath = URL(
      fileURLWithPath: "/Applications/WattWhat.app/Contents/MacOS/WattWhat"
    ).resolvingSymlinksInPath().path
    let trustedBundleCLIPath = URL(
      fileURLWithPath: "/Applications/WattWhat.app/Contents/MacOS/wattctl"
    ).resolvingSymlinksInPath().path
    let trustedSystemCLIPath = URL(
      fileURLWithPath: HelperConstants.cliInstallPath
    ).resolvingSymlinksInPath().path

    let trustedPaths: Set<String> = [
      trustedAppPath,
      trustedBundleCLIPath,
      trustedSystemCLIPath,
    ]
    guard trustedPaths.contains(resolvedPath) else {
      return "Yetkisiz istemci: Güvenilmeyen ikili dosya konumu (\(resolvedPath))."
    }

    var guestCode: SecCode?
    let guestAttributes: [CFString: Any] = [kSecGuestAttributePid: peerPID]
    guard
      SecCodeCopyGuestWithAttributes(nil, guestAttributes as CFDictionary, [], &guestCode)
        == errSecSuccess,
      let guestCode,
      SecCodeCheckValidity(guestCode, [], nil) == errSecSuccess
    else {
      return "Yetkisiz istemci: Çalışan sürecin kod imzası doğrulanamadı."
    }

    var staticCode: SecStaticCode?
    let fileURL = URL(fileURLWithPath: resolvedPath) as CFURL
    guard SecStaticCodeCreateWithPath(fileURL, [], &staticCode) == errSecSuccess,
      let staticCode,
      SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSBasicValidateOnly), nil)
        == errSecSuccess
    else {
      return "Yetkisiz istemci: İkili dosyanın kod imzası geçersiz."
    }

    var signingInfo: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
      let infoDict = signingInfo as? [String: Any],
      let signingID = infoDict[kSecCodeInfoIdentifier as String] as? String
    else {
      return "Yetkisiz istemci: Kod imzası tanımlayıcısı okunamadı."
    }

    if resolvedPath == trustedAppPath {
      guard signingID == "com.kuarezma.wattwhat" else {
        return "Yetkisiz istemci: Uygulama bundle kimliği uyuşmuyor (\(signingID))."
      }
    } else {
      let isTrustedCLIIdentifier =
        signingID == "com.kuarezma.wattwhat"
        || signingID == "wattctl"
        || signingID.hasPrefix("wattctl-")
      guard isTrustedCLIIdentifier else {
        return "Yetkisiz istemci: CLI kod imzası kimliği uyuşmuyor (\(signingID))."
      }
    }

    return nil
  }
}

struct ReadonlyProbeOutput: Codable {
  let timestamp: Date
  let telemetry: LivePowerTelemetry
  let smcDiagnostics: [SMCKeyDiagnostic]
}

// MARK: - Entry Point

let args = CommandLine.arguments
if args.contains("--probe-readonly") {
  let telemetry = PowerTelemetryReader.read()
  let diagnostics = AppleSMCClient.probeReadableChargerKeys()
  let payload = ReadonlyProbeOutput(
    timestamp: Date(),
    telemetry: telemetry,
    smcDiagnostics: diagnostics
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.dateEncodingStrategy = .iso8601
  if let data = try? encoder.encode(payload), let json = String(data: data, encoding: .utf8) {
    print(json)
  }
  exit(0)
}

if args.contains("--restore-baseline") {
  let url = URL(fileURLWithPath: HelperConstants.baselineFilePath)
  if let data = try? Data(contentsOf: url),
    let snapshot = try? JSONDecoder().decode(SMCBaselineSnapshot.self, from: data),
    let client = try? AppleSMCClient()
  {
    _ = client.restoreBaseline(snapshot)
    print("Baseline restored.")
  }
  exit(0)
}

if args.contains("--daemon") {
  signal(SIGPIPE, SIG_IGN)
  let engine = PowerControlEngine()
  signal(SIGTERM, SIG_IGN)
  signal(SIGINT, SIG_IGN)
  let shutdownHandler: @Sendable () -> Void = {
    engine.restoreBaselineOnShutdown()
    unlink(HelperConstants.socketPath)
    exit(0)
  }
  let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
  termSource.setEventHandler(handler: shutdownHandler)
  termSource.resume()

  let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
  intSource.setEventHandler(handler: shutdownHandler)
  intSource.resume()

  engine.startLoop()
  let server = SocketServer(engine: engine)
  withExtendedLifetime((termSource, intSource)) {
    server.run()
  }
}

print("Kullanım: wattwhat-helper [--daemon | --probe-readonly | --restore-baseline]")
