import Darwin
import Foundation

final class PowerControlEngine: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.kuarezma.wattwhat.helper.engine")
  private var config: ChargeControlConfig
  private var baseline: SMCBaselineSnapshot?
  private var hasDirtySMCChanges = false
  private var isInHysteresisHold = false
  private var lastAppliedLED: MagSafeLEDMode?
  private var lastWriteResults: [String: String] = [:]
  private var activeMethod: RegulationMethod = .automaticOS
  private var effectiveReason: String = "macOS otomatik güç yönetimi devrede"
  private var appliedTargetWatts: Int?
  private var currentDutyRatio: Double?

  // Kapalı çevrim geri besleme ve makro-darbe zamanlayıcı durumu
  private var closedLoopScale: Double = 1.0
  private var limitStartDate: Date?
  private var lastLimitTargetWatts: Int?
  private var observedPeakWatts: Double = 30.0
  private var useMacroPulseFallback = false
  private var pulseWindowStart: Date = Date()

  private var timer: DispatchSourceTimer?

  init() {
    self.config = Self.loadConfigFromDisk()
    self.baseline = Self.loadBaselineFromDisk()
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
      if hasDirtySMCChanges, let baseline {
        if let client = try? AppleSMCClient() {
          lastWriteResults = client.restoreBaseline(baseline)
        }
        hasDirtySMCChanges = false
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
            closedLoopScale = 1.0
            limitStartDate = nil
            lastLimitTargetWatts = nil
            useMacroPulseFallback = false
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
        closedLoopScale = 1.0
        limitStartDate = nil
        useMacroPulseFallback = false
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
        Self.saveConfigToDisk(config)
        if let baseline, let client = try? AppleSMCClient() {
          lastWriteResults = client.restoreBaseline(baseline)
        }
        hasDirtySMCChanges = false
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

    if telemetry.batteryChargeWatts > observedPeakWatts && telemetry.isCharging {
      observedPeakWatts = telemetry.batteryChargeWatts
    }
    if telemetry.adapterRatingWatts > 0 {
      observedPeakWatts = max(observedPeakWatts, Double(telemetry.adapterRatingWatts))
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

    if baseline == nil {
      let captured = client.captureBaseline()
      baseline = captured
      Self.saveBaselineToDisk(captured)
    }

    // LED kontrolü (yalnız değiştiğinde veya aktif müdahale sırasında)
    applyLEDIfNeeded(client: client, mode: evaluation.effectiveLED)

    switch evaluation.command {
    case .restoreAutomatic(let reason):
      if hasDirtySMCChanges, let baseline {
        lastWriteResults = client.restoreBaseline(baseline)
        hasDirtySMCChanges = false
      }
      activeMethod = .automaticOS
      effectiveReason = reason
      appliedTargetWatts = nil
      currentDutyRatio = nil
      limitStartDate = nil
      useMacroPulseFallback = false
      closedLoopScale = 1.0

    case .inhibitCharging(let reason):
      ensureBaselineCaptured(client: client)
      hasDirtySMCChanges = true
      let inhibitOK = setChargingInhibit(client: client, inhibit: true)
      _ = setAdapterSuspend(client: client, suspend: false)
      activeMethod = inhibitOK ? .hardwareInhibit : .firmwareRestricted
      effectiveReason =
        inhibitOK
        ? reason
        : "\(reason) (Uyarı: Firmware şarj durdurma anahtarını reddetti)"
      appliedTargetWatts = 0
      currentDutyRatio = 0.0
      limitStartDate = nil
      useMacroPulseFallback = false

    case .forceDischarge(let untilPercent, let reason):
      ensureBaselineCaptured(client: client)
      hasDirtySMCChanges = true
      let suspendOK = setAdapterSuspend(client: client, suspend: true)
      _ = setChargingInhibit(client: client, inhibit: true)
      activeMethod = suspendOK ? .adapterSuspend : .firmwareRestricted
      effectiveReason =
        suspendOK
        ? "\(reason) (Hedef: %\(untilPercent))"
        : "Firmware adaptör kesme anahtarını (CHIE) kabul etmedi"
      appliedTargetWatts = 0
      currentDutyRatio = nil
      limitStartDate = nil
      useMacroPulseFallback = false

    case .limitWatts(let watts, let scope, let maxPercent, let hysteresis, let reason):
      ensureBaselineCaptured(client: client)
      hasDirtySMCChanges = true
      _ = setAdapterSuspend(client: client, suspend: false)

      // Tavan anahtarı (CHLT) güncelle
      if maxPercent < 100 {
        recordWrite(
          client: client, key: "CHLT",
          bytes: [UInt8(maxPercent), UInt8(hysteresis), UInt8(hysteresis)])
      } else if let origCHLT = baseline?.keys["CHLT"] {
        recordWrite(client: client, key: "CHLT", bytes: origCHLT)
      }

      if lastLimitTargetWatts != watts {
        lastLimitTargetWatts = watts
        limitStartDate = now
        useMacroPulseFallback = false
        closedLoopScale = 1.0
      } else if limitStartDate == nil {
        limitStartDate = now
      }

      let measuredWatts =
        scope == .batteryNetWatts
        ? telemetry.batteryChargeWatts
        : (telemetry.systemInputWatts > 0
          ? telemetry.systemInputWatts : telemetry.batteryChargeWatts + telemetry.systemLoadWatts)

      // Kapalı çevrim ince ayar (yalnız şarj aktifken ve darbe yedek modunda değilken)
      if !useMacroPulseFallback && telemetry.isPluggedIn && telemetry.isCharging && measuredWatts > 0.5 {
        let ratio = Double(watts) / measuredWatts
        if ratio < 0.90 || ratio > 1.12 {
          let adjusted = closedLoopScale * (0.6 + 0.4 * ratio)
          closedLoopScale = min(max(adjusted, 0.30), 1.45)
        }
      }

      let anyDirectWriteOK = applyDirectWattLimitKeys(
        client: client,
        targetWatts: watts,
        scope: scope,
        telemetry: telemetry,
        scale: closedLoopScale
      )

      // 8 saniye sonra gerçek ölçüm hedefin çok üstünde kaldıysa veya doğrudan anahtarlar reddedildiyse
      let elapsed = now.timeIntervalSince(limitStartDate ?? now)
      let exceedsTarget =
        telemetry.isPluggedIn && telemetry.isCharging
        && measuredWatts > (Double(watts) * 1.30 + 2.0)

      if !useMacroPulseFallback && elapsed >= 8.0 && (!anyDirectWriteOK || exceedsTarget) {
        if config.allowDutyCycleFallback {
          useMacroPulseFallback = true
          pulseWindowStart = now
        }
      }

      if useMacroPulseFallback {
        let peak = max(observedPeakWatts, Double(telemetry.adapterRatingWatts), Double(watts) * 1.5, 20.0)
        let rawDuty = Double(watts) / peak
        let duty = min(max(rawDuty, 0.12), 0.92)
        let windowSeconds = 60.0
        var phase = now.timeIntervalSince(pulseWindowStart)
        if phase >= windowSeconds {
          pulseWindowStart = now
          phase = 0
        }
        let onSeconds = max(6.0, min(windowSeconds - 6.0, windowSeconds * duty))
        let allowChargeNow = phase < onSeconds
        let chilOK = setChargingInhibit(client: client, inhibit: !allowChargeNow)
        activeMethod = chilOK ? .macroPulseModulation : .firmwareRestricted
        currentDutyRatio = duty
        appliedTargetWatts = watts
        effectiveReason =
          chilOK
          ? "\(reason) · Darbe %\(Int((duty * 100).rounded())) (\(Int(onSeconds))sn açık / \(Int(windowSeconds - onSeconds))sn beklet)"
          : "Firmware hem akım sınırlama hem CHIL anahtarlarını kısıtladı"
      } else {
        _ = setChargingInhibit(client: client, inhibit: false)
        activeMethod = anyDirectWriteOK ? .directSMCHardware : .firmwareRestricted
        currentDutyRatio = nil
        appliedTargetWatts = watts
        effectiveReason =
          anyDirectWriteOK
          ? reason
          : "Firmware akım/güç anahtarlarını salt-okunur tutuyor"
      }
    }
  }

  private func ensureBaselineCaptured(client: AppleSMCClient) {
    if baseline == nil {
      let captured = client.captureBaseline()
      baseline = captured
      Self.saveBaselineToDisk(captured)
    }
  }

  private func applyLEDIfNeeded(client: AppleSMCClient, mode: MagSafeLEDMode) {
    if mode == .automatic {
      if lastAppliedLED != nil && lastAppliedLED != .automatic {
        if let orig = baseline?.keys["ACLC"] {
          recordWrite(client: client, key: "ACLC", bytes: orig)
        } else {
          recordWrite(client: client, key: "ACLC", bytes: [0x00])
        }
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

  private func applyDirectWattLimitKeys(
    client: AppleSMCClient,
    targetWatts: Int,
    scope: WattTargetScope,
    telemetry: LivePowerTelemetry,
    scale: Double
  ) -> Bool {
    var anyOK = false
    let battV = telemetry.batteryVoltage_V > 5.0 ? telemetry.batteryVoltage_V : 12.6
    let adapterV = telemetry.adapterVoltage_V > 4.0 ? telemetry.adapterVoltage_V : 20.0
    let sysLoad = max(telemetry.systemLoadWatts, 3.0)

    let effectiveBattWatts: Double
    let effectiveAdapterWatts: Double
    switch scope {
    case .batteryNetWatts:
      effectiveBattWatts = Double(targetWatts) * scale
      effectiveAdapterWatts = effectiveBattWatts + sysLoad + 1.0
    case .adapterInputWatts:
      effectiveAdapterWatts = Double(targetWatts) * scale
      effectiveBattWatts = max(effectiveAdapterWatts - sysLoad - 0.5, 2.0)
    }

    let targetBatt_mA = UInt32(min(max(Int((effectiveBattWatts / battV) * 1_000.0), 250), 6000))
    let targetAdapter_mW = UInt32(min(max(Int((effectiveAdapterWatts * 1_000.0).rounded()), 5_000), 140_000))
    let targetAdapter_mA = UInt32(
      min(max(Int(((effectiveAdapterWatts / adapterV) * 1_000.0).rounded()), 300), 5000))

    for key in ["BTIL", "BTSI"] {
      if recordWrite(client: client, key: key, bytes: AppleSMCClient.encodeUInt32LE(targetBatt_mA)) {
        anyOK = true
      }
    }

    if recordWrite(client: client, key: "CIPW", bytes: AppleSMCClient.encodeUInt32LE(targetAdapter_mW)) {
      anyOK = true
    }
    let ratioByte: UInt8 =
      telemetry.adapterRatingWatts > 0
      ? UInt8(min(max(Int((effectiveAdapterWatts / Double(telemetry.adapterRatingWatts)) * 100.0), 10), 100))
      : 0xFF
    _ = recordWrite(client: client, key: "CIPR", bytes: [ratioByte])

    for key in ["CIPI", "CHAS", "CHA1", "CHA2", "CHAI", "CHI1", "CHI2", "ACLM"] {
      if recordWrite(client: client, key: key, bytes: AppleSMCClient.encodeUInt32LE(targetAdapter_mA)) {
        anyOK = true
      }
    }
    return anyOK
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

  private func handleClient(_ clientFD: Int32) {
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    if getpeereid(clientFD, &peerUID, &peerGID) == 0 {
      // Yalnızca root (0) veya konsol kullanıcıları (>= 500) kabul edilir
      if peerUID != 0 && peerUID < 500 {
        return
      }
    }

    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.recv(clientFD, &buffer, buffer.count, 0)
      if count <= 0 { break }
      received.append(buffer, count: count)
      if buffer[0..<count].contains(0x0A) { break }
    }
    if let newline = received.firstIndex(of: 0x0A) {
      received = received[..<newline]
    }
    guard !received.isEmpty,
      let request = try? JSONDecoder().decode(HelperRequest.self, from: received)
    else { return }

    let response = engine.handleRequest(request)
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
  let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
  termSource.setEventHandler {
    unlink(HelperConstants.socketPath)
    exit(0)
  }
  termSource.resume()

  engine.startLoop()
  let server = SocketServer(engine: engine)
  server.run()
}

print("Kullanım: wattwhat-helper [--daemon | --probe-readonly | --restore-baseline]")
