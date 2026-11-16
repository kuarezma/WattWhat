import Foundation
import Testing

@testable import WattWhatCore

@Test("HelperInstaller sabit geliştirici kullanıcı yolu içermez ve varsayılan dizine düşer")
func helperInstallerAvoidsHardcodedDeveloperPath() {
  let dir = HelperInstaller.bundleExecutableDirectory()
  #expect(!dir.path.contains("/Users/"))
  #expect(dir.path == "/Applications/WattWhat.app/Contents/MacOS")
}

@Test("HelperInstaller tek tırnak kaçışı özel karakterleri güvenli biçimde sarar")
func helperInstallerShellQuotingEscapesSpecialCharacters() throws {
  let maliciousDir = URL(fileURLWithPath: "/tmp/Watt's $(id) `uname` \"App\"/Contents/MacOS")
  let script = HelperInstaller.installShellScript(sourceDir: maliciousDir)

  #expect(script.contains("'/tmp/Watt'\\''s $(id) `uname` \"App\"/Contents/MacOS/wattwhat-helper'"))
  #expect(script.contains("'/tmp/Watt'\\''s $(id) `uname` \"App\"/Contents/MacOS/wattctl'"))
  #expect(!script.contains("\"\(maliciousDir.path)"))

  // Bash sözdizimi doğrulaması
  let tempScript = FileManager.default.temporaryDirectory
    .appendingPathComponent("wattwhat-syntax-\(UUID().uuidString).sh")
  try script.write(to: tempScript, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: tempScript) }

  let syntaxCheck = Process()
  syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/bash")
  syntaxCheck.arguments = ["-n", tempScript.path]
  try syntaxCheck.run()
  syntaxCheck.waitUntilExit()
  #expect(syntaxCheck.terminationStatus == 0)

  // Tek tırnak kaçışının bash tarafından birebir aynı dizeye çözüldüğünü doğrula
  let quoted = HelperInstaller.shellQuoted(maliciousDir.path)
  let echoProcess = Process()
  echoProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
  echoProcess.arguments = ["-c", "printf '%s' \(quoted)"]
  let pipe = Pipe()
  echoProcess.standardOutput = pipe
  try echoProcess.run()
  echoProcess.waitUntilExit()
  let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
  #expect(echoProcess.terminationStatus == 0)
  #expect(output == maliciousDir.path)
}

@Test("HelperRequest ve HelperResponse JSON kodlama/çözme roundtrip tutarlıdır")
func helperRequestAndResponseJSONRoundtrip() throws {
  var config = ChargeControlConfig.defaultConfig
  config.mode = .manualWatts
  config.targetWatts = 22
  config.maxChargeLimitPercent = 85

  let request = HelperRequest(command: .applyConfig, config: config, lowPowerMode: nil)
  let requestData = try JSONEncoder().encode(request)
  let decodedRequest = try JSONDecoder().decode(HelperRequest.self, from: requestData)

  #expect(decodedRequest.command == .applyConfig)
  #expect(decodedRequest.config == config)
  #expect(decodedRequest.lowPowerMode == nil)

  let lpmRequest = HelperRequest(command: .setLowPowerMode, lowPowerMode: true)
  let lpmDecoded = try JSONDecoder().decode(
    HelperRequest.self,
    from: JSONEncoder().encode(lpmRequest)
  )
  #expect(lpmDecoded.command == .setLowPowerMode)
  #expect(lpmDecoded.lowPowerMode == true)

  let response = HelperResponse(
    ok: false,
    isHelperRunning: true,
    helperVersion: HelperConstants.protocolVersion,
    activeRegulationMethod: .automaticOS,
    effectiveReason: "Yetkisiz istemci",
    appliedTargetWatts: nil,
    currentDutyCycleRatio: nil,
    config: config,
    telemetry: .empty,
    smcDiagnostics: [],
    errorMessage: "Yetkisiz istemci: Güvenilmeyen ikili dosya konumu."
  )
  let responseData = try JSONEncoder().encode(response)
  let decodedResponse = try JSONDecoder().decode(HelperResponse.self, from: responseData)

  #expect(decodedResponse.ok == false)
  #expect(decodedResponse.isHelperRunning == true)
  #expect(decodedResponse.config == config)
  #expect(decodedResponse.errorMessage == "Yetkisiz istemci: Güvenilmeyen ikili dosya konumu.")
  #expect(!decodedResponse.isHelperOutdated)
}
