import Foundation

private func printUsage() {
  print("""
  WattWhat Şarj & Güç Kontrol CLI (wattctl v\(HelperConstants.protocolVersion))

  Kullanım:
    wattctl status [--json]              Canlı güç akışı, USB-PD profilleri ve aktif mod
    wattctl auto                         macOS otomatik yönetimine devret
    wattctl watt <5..140> [--battery | --adapter]
                                         Belirlenen Watt gücüyle şarj et
    wattctl passthrough                  Şarjı durdur (0W), doğrudan adaptörden çalış
    wattctl discharge [hedef_yuzde]      Belirtilen yüzdeye kadar pilden tüket (varsayılan %60)
    wattctl limit <50..100>              Maksimum şarj tavanını ayarla
    wattctl topup                        Tek seferlik %100'e tamamla
    wattctl led <auto|green|amber|off>   MagSafe 3 LED kontrolü
    wattctl lpm <on|off>                 macOS Düşük Güç Modunu aç/kapat
    wattctl probe                        AppleSMC şarj/güç anahtar matrisini dök
    wattctl install                      Yetkili arka plan servisini yönetici izniyle kur
    wattctl uninstall                    Yetkili servisi kaldır ve fabrika ayarlarına dön
  """)
}

private func currentConfigFromHelperOrLocal() -> (config: ChargeControlConfig, response: HelperResponse?) {
  if case .success(let resp) = HelperIPCClient.send(HelperRequest(command: .status)) {
    return (resp.config, resp)
  }
  return (LocalConfigStore.load(), nil)
}

private func sendWriteRequest(_ request: HelperRequest) -> Int32 {
  switch HelperIPCClient.send(request) {
  case .success(let resp):
    LocalConfigStore.save(resp.config)
    print("✅ Uygulandı: \(resp.effectiveReason)")
    print("   Katman: \(resp.activeRegulationMethod.rawValue)")
    if let w = resp.appliedTargetWatts {
      print("   Hedef Güç: \(w) W")
    }
    return resp.ok ? 0 : 1
  case .failure:
    fputs(
      """
      ❌ Yetkili Güç Motoru (wattwhat-helper) henüz aktif değil.
      Çözüm 1: Menü çubuğundaki WattWhat -> 'Şarj & Güç Stüdyosu' -> 'Yetkili Güç Motorunu Etkinleştir' butonuna tıklayın.
      Çözüm 2: Terminalden 'wattctl install' komutunu çalıştırın.
      \n
      """,
      stderr
    )
    return 2
  }
}

private func printStatus(json: Bool) -> Int32 {
  let telemetry = PowerTelemetryReader.read()
  let (_, resp) = currentConfigFromHelperOrLocal()
  let effectiveResponse =
    resp
    ?? HelperResponse.offline(
      config: LocalConfigStore.load(),
      telemetry: telemetry,
      diagnostics: AppleSMCClient.probeReadableChargerKeys()
    )

  if json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(effectiveResponse),
      let str = String(data: data, encoding: .utf8)
    {
      print(str)
      return 0
    }
    return 1
  }

  let t = effectiveResponse.telemetry
  print("⚡️ WattWhat Güç Kontrol Durumu (v\(HelperConstants.protocolVersion))")
  print("────────────────────────────────────────────────────────────")
  print(
    String(
      format: "Pil          : %%%.0f  | %.2f V  | %+.2f A  | %.1f W  | %@",
      t.batteryPercent,
      t.batteryVoltage_V,
      t.batteryCurrent_A,
      t.batteryChargeWatts,
      t.isCharging ? "Şarj Oluyor" : (t.isPluggedIn ? "Fişte (Beklemede)" : "Pilde")
    ))
  if let temp = t.batteryTemp_C {
    print(String(format: "Pil Sıcaklığı: %.1f °C", temp))
  }
  if t.isPluggedIn {
    print(
      String(
        format: "Adaptör      : %d W nominal  | %.2f V  | %.2f A  | Giriş: %.1f W  | Sistem Yükü: %.1f W",
        t.adapterRatingWatts,
        t.adapterVoltage_V,
        t.adapterCurrent_A,
        t.systemInputWatts,
        t.systemLoadWatts
      ))
    if !t.pdoProfiles.isEmpty {
      let pdoList = t.pdoProfiles.map { p in
        let mark = (t.activePDOIndex == p.index) ? "*" : ""
        return String(format: "%@%.0fV/%.0fW", mark, p.maxVoltage_V, p.maxWatts)
      }.joined(separator: "  ")
      print("USB-PD PDO   : \(pdoList)")
    }
  }
  print("Servis       : \(effectiveResponse.isHelperRunning ? "Aktif 🟢" : "Kurulu/Aktif Değil 🟡")")
  print("Aktif Mod    : \(effectiveResponse.config.mode.title)")
  print("Regülasyon   : \(effectiveResponse.activeRegulationMethod.rawValue)")
  print("Durum Notu   : \(effectiveResponse.effectiveReason)")
  if effectiveResponse.config.mode == .manualWatts {
    print("Hedef Watt   : \(effectiveResponse.config.targetWatts) W (\(effectiveResponse.config.targetScope.title))")
  }
  print("Tavan Limiti : %\(effectiveResponse.config.maxChargeLimitPercent) (Histerezis %\(effectiveResponse.config.hysteresisPercent))")
  return 0
}

private func printProbe() -> Int32 {
  let diags: [SMCKeyDiagnostic]
  if case .success(let resp) = HelperIPCClient.send(HelperRequest(command: .probeHardware)) {
    diags = resp.smcDiagnostics
  } else {
    diags = AppleSMCClient.probeReadableChargerKeys()
  }
  print("ANAHTAR | TİP  | BOYUT | ATTR | DEĞER (HEX)      | SAYISAL       | SON YAZMA")
  print("────────┼──────┼───────┼──────┼──────────────────┼───────────────┼────────────────")
  for d in diags {
    let key = d.key.padding(toLength: 7, withPad: " ", startingAt: 0)
    let dt = d.dataType.padding(toLength: 4, withPad: " ", startingAt: 0)
    let sz = String(format: "%5d", d.dataSize)
    let attr = String(format: "0x%02x", d.attributes)
    let hex = d.currentHex.padding(toLength: 16, withPad: " ", startingAt: 0)
    let num = d.numericSummary.padding(toLength: 13, withPad: " ", startingAt: 0)
    let wr = d.lastWriteResult ?? "-"
    print("\(key) | \(dt) | \(sz) | \(attr) | \(hex) | \(num) | \(wr)")
  }
  return 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let sub = arguments.first else {
  printUsage()
  exit(0)
}

switch sub {
case "status":
  exit(printStatus(json: arguments.contains("--json")))

case "probe":
  exit(printProbe())

case "auto":
  exit(sendWriteRequest(HelperRequest(command: .setAutomatic)))

case "watt":
  guard arguments.count >= 2, let w = Int(arguments[1]), (5...140).contains(w) else {
    fputs("Hata: Geçerli bir Watt değeri girin (5 - 140). Örn: wattctl watt 15\n", stderr)
    exit(1)
  }
  var (cfg, _) = currentConfigFromHelperOrLocal()
  cfg.mode = .manualWatts
  cfg.targetWatts = w
  if arguments.contains("--adapter") {
    cfg.targetScope = .adapterInputWatts
  } else if arguments.contains("--battery") {
    cfg.targetScope = .batteryNetWatts
  }
  exit(sendWriteRequest(HelperRequest(command: .applyConfig, config: cfg)))

case "passthrough":
  var (cfg, _) = currentConfigFromHelperOrLocal()
  cfg.mode = .passthroughHold
  exit(sendWriteRequest(HelperRequest(command: .applyConfig, config: cfg)))

case "discharge":
  var (cfg, _) = currentConfigFromHelperOrLocal()
  cfg.mode = .forceDischarge
  if arguments.count >= 2, let pct = Int(arguments[1]) {
    cfg.dischargeTargetPercent = min(max(pct, 20), 90)
  }
  exit(sendWriteRequest(HelperRequest(command: .applyConfig, config: cfg)))

case "limit":
  guard arguments.count >= 2, let limit = Int(arguments[1]), (50...100).contains(limit) else {
    fputs("Hata: Geçerli bir yüzde limiti girin (50 - 100).\n", stderr)
    exit(1)
  }
  var (cfg, _) = currentConfigFromHelperOrLocal()
  cfg.maxChargeLimitPercent = limit
  cfg.topUpTo100Active = false
  if cfg.mode == .automatic && limit < 100 {
    cfg.mode = .manualWatts
  }
  exit(sendWriteRequest(HelperRequest(command: .applyConfig, config: cfg)))

case "topup":
  var (cfg, _) = currentConfigFromHelperOrLocal()
  cfg.mode = .manualWatts
  cfg.topUpTo100Active = true
  exit(sendWriteRequest(HelperRequest(command: .applyConfig, config: cfg)))

case "led":
  guard arguments.count >= 2, let mode = MagSafeLEDMode(rawValue: arguments[1]) else {
    fputs("Hata: led değeri auto, green, amber veya off olmalıdır.\n", stderr)
    exit(1)
  }
  var (cfg, _) = currentConfigFromHelperOrLocal()
  cfg.ledMode = mode
  exit(sendWriteRequest(HelperRequest(command: .applyConfig, config: cfg)))

case "lpm":
  guard arguments.count >= 2 else {
    fputs("Hata: lpm değeri on veya off olmalıdır.\n", stderr)
    exit(1)
  }
  let enabled = (arguments[1] == "on" || arguments[1] == "1" || arguments[1] == "true")
  exit(sendWriteRequest(HelperRequest(command: .setLowPowerMode, lowPowerMode: enabled)))

case "install":
  switch HelperInstaller.installWithAdminPrompt() {
  case .success:
    print("✅ Yetkili Güç Motoru başarıyla kuruldu ve başlatıldı.")
    exit(0)
  case .failure(let err):
    fputs("❌ Kurulum başarısız: \(err.localizedDescription)\n", stderr)
    exit(1)
  }

case "uninstall":
  switch HelperInstaller.uninstallWithAdminPrompt() {
  case .success:
    print("✅ Yetkili Güç Motoru kaldırıldı ve fabrika ayarları geri yüklendi.")
    exit(0)
  case .failure(let err):
    fputs("❌ Kaldırma başarısız: \(err.localizedDescription)\n", stderr)
    exit(1)
  }

default:
  printUsage()
  exit(1)
}
