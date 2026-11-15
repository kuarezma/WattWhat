import Darwin
import Foundation

enum HelperConstants {
  static let protocolVersion = "2.0.0"
  static let machLabel = "com.kuarezma.wattwhat.helper"
  static let socketPath = "/var/run/wattwhat.sock"
  static let helperInstallPath = "/Library/PrivilegedHelperTools/com.kuarezma.wattwhat.helper"
  static let launchDaemonPlistPath = "/Library/LaunchDaemons/com.kuarezma.wattwhat.helper.plist"
  static let cliInstallPath = "/usr/local/bin/wattctl"
  static let configFilePath = "/var/db/wattwhat-config.json"
  static let baselineFilePath = "/var/db/wattwhat-smc-baseline.json"
  static let appDefaultsSuite = "com.kuarezma.wattwhat"
}

enum RegulationMethod: String, Codable, Sendable {
  case automaticOS = "Otomatik (macOS Yönetimi)"
  case directSMCHardware = "Doğrudan Donanım Akım/Güç Sınırlama"
  case macroPulseModulation = "Akıllı Makro-Darbe Regülasyonu (CHIL)"
  case hardwareInhibit = "Donanım Şarj Durdurma (Passthrough)"
  case adapterSuspend = "Adaptör Askıda (Pilden Kullanım)"
  case firmwareRestricted = "Firmware Yazma Kısıtı (Salt İzleme)"
  case helperOffline = "Yetkili Servis Kurulu Değil"
}

enum HelperCommand: String, Codable, Sendable {
  case status
  case applyConfig
  case setAutomatic
  case probeHardware
  case setLowPowerMode
  case uninstallCleanup
}

struct HelperRequest: Codable, Sendable {
  let command: HelperCommand
  let config: ChargeControlConfig?
  let lowPowerMode: Bool?

  init(
    command: HelperCommand,
    config: ChargeControlConfig? = nil,
    lowPowerMode: Bool? = nil
  ) {
    self.command = command
    self.config = config
    self.lowPowerMode = lowPowerMode
  }
}

struct HelperResponse: Codable, Sendable {
  let ok: Bool
  let isHelperRunning: Bool
  let helperVersion: String
  let activeRegulationMethod: RegulationMethod
  let effectiveReason: String
  let appliedTargetWatts: Int?
  let currentDutyCycleRatio: Double?
  let config: ChargeControlConfig
  let telemetry: LivePowerTelemetry
  let smcDiagnostics: [SMCKeyDiagnostic]
  let errorMessage: String?

  static func offline(
    config: ChargeControlConfig,
    telemetry: LivePowerTelemetry,
    diagnostics: [SMCKeyDiagnostic] = [],
    error: String? = nil
  ) -> HelperResponse {
    HelperResponse(
      ok: false,
      isHelperRunning: false,
      helperVersion: HelperConstants.protocolVersion,
      activeRegulationMethod: .helperOffline,
      effectiveReason: "Yetkili Güç Motoru (LaunchDaemon) aktif değil",
      appliedTargetWatts: nil,
      currentDutyCycleRatio: nil,
      config: config,
      telemetry: telemetry,
      smcDiagnostics: diagnostics,
      errorMessage: error
    )
  }
}

enum LocalConfigStore {
  private static let defaultsKey = "wattwhatChargeControlConfigV2"

  static func load() -> ChargeControlConfig {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode(ChargeControlConfig.self, from: data)
    else {
      return .defaultConfig
    }
    return decoded.clamped()
  }

  static func save(_ config: ChargeControlConfig) {
    guard let data = try? JSONEncoder().encode(config.clamped()) else { return }
    UserDefaults.standard.set(data, forKey: defaultsKey)
  }
}

enum HelperIPCClient {
  static var isHelperInstalled: Bool {
    FileManager.default.fileExists(atPath: HelperConstants.helperInstallPath)
      && FileManager.default.fileExists(atPath: HelperConstants.launchDaemonPlistPath)
  }

  static var isSocketReachable: Bool {
    FileManager.default.fileExists(atPath: HelperConstants.socketPath)
  }

  static func send(_ request: HelperRequest, timeoutSeconds: Double = 2.0) -> Result<HelperResponse, Error> {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
    }
    defer { close(fd) }

    var tv = timeval(
      tv_sec: Int(timeoutSeconds),
      tv_usec: suseconds_t((timeoutSeconds - floor(timeoutSeconds)) * 1_000_000)
    )
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(HelperConstants.socketPath.utf8CString)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= maxLen else {
      return .failure(
        NSError(
          domain: "WattWhatIPC", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Socket yolu çok uzun"]))
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
      for (i, byte) in pathBytes.enumerated() {
        dest[i] = UInt8(bitPattern: byte)
      }
    }

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(fd, sockPtr, addrLen)
      }
    }
    guard connectResult == 0 else {
      let err = errno
      return .failure(
        NSError(
          domain: NSPOSIXErrorDomain, code: Int(err),
          userInfo: [NSLocalizedDescriptionKey: "Yetkili servis bağlantısı kurulamadı (\(err))"]))
    }

    do {
      var payload = try JSONEncoder().encode(request)
      payload.append(0x0A)
      try payload.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < payload.count {
          let written = Darwin.send(fd, base.advanced(by: sent), payload.count - sent, 0)
          if written <= 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
          }
          sent += written
        }
      }

      var received = Data()
      var buffer = [UInt8](repeating: 0, count: 8192)
      while true {
        let count = Darwin.recv(fd, &buffer, buffer.count, 0)
        if count < 0 {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if count == 0 { break }
        received.append(buffer, count: count)
        if buffer[0..<count].contains(0x0A) { break }
      }

      if let newline = received.firstIndex(of: 0x0A) {
        received = received[..<newline]
      }
      let response = try JSONDecoder().decode(HelperResponse.self, from: received)
      return .success(response)
    } catch {
      return .failure(error)
    }
  }
}

enum HelperInstaller {
  static func bundleExecutableDirectory() -> URL {
    if let execURL = Bundle.main.executableURL {
      let candidate = execURL.deletingLastPathComponent()
      if FileManager.default.fileExists(
        atPath: candidate.appendingPathComponent("wattwhat-helper").path)
      {
        return candidate
      }
    }
    let fallback = URL(fileURLWithPath: "/Applications/WattWhat.app/Contents/MacOS")
    return fallback
  }

  static func launchDaemonPlistContent() -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(HelperConstants.machLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(HelperConstants.helperInstallPath)</string>
            <string>--daemon</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>/var/log/wattwhat-helper.log</string>
        <key>StandardErrorPath</key>
        <string>/var/log/wattwhat-helper.err</string>
    </dict>
    </plist>
    """
  }

  static func installShellScript(sourceDir: URL) -> String {
    let helperSrc = sourceDir.appendingPathComponent("wattwhat-helper").path
    let cliSrc = sourceDir.appendingPathComponent("wattctl").path
    let plistBody = launchDaemonPlistContent()
    return """
    #!/bin/bash
    set -euo pipefail
    mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons /usr/local/bin /var/db
    if [ ! -f "\(helperSrc)" ]; then
      echo "HATA: wattwhat-helper bulunamadı: \(helperSrc)" >&2
      exit 1
    fi
    /bin/launchctl bootout system/\(HelperConstants.machLabel) >/dev/null 2>&1 || true
    /bin/cp -f "\(helperSrc)" "\(HelperConstants.helperInstallPath)"
    /usr/sbin/chown root:wheel "\(HelperConstants.helperInstallPath)"
    /bin/chmod 755 "\(HelperConstants.helperInstallPath)"
    if [ -f "\(cliSrc)" ]; then
      /bin/cp -f "\(cliSrc)" "\(HelperConstants.cliInstallPath)"
      /usr/sbin/chown root:wheel "\(HelperConstants.cliInstallPath)"
      /bin/chmod 755 "\(HelperConstants.cliInstallPath)"
    fi
    cat << 'PLIST_EOF' > "\(HelperConstants.launchDaemonPlistPath)"
    \(plistBody)
    PLIST_EOF
    /usr/sbin/chown root:wheel "\(HelperConstants.launchDaemonPlistPath)"
    /bin/chmod 644 "\(HelperConstants.launchDaemonPlistPath)"
    /bin/launchctl bootstrap system "\(HelperConstants.launchDaemonPlistPath)"
    /bin/launchctl kickstart -k system/\(HelperConstants.machLabel) >/dev/null 2>&1 || true
    sleep 1
    echo "OK"
    """
  }

  static func uninstallShellScript() -> String {
    """
    #!/bin/bash
    set -euo pipefail
    if [ -x "\(HelperConstants.helperInstallPath)" ]; then
      "\(HelperConstants.helperInstallPath)" --restore-baseline >/dev/null 2>&1 || true
    fi
    /bin/launchctl bootout system/\(HelperConstants.machLabel) >/dev/null 2>&1 || true
    /bin/rm -f "\(HelperConstants.launchDaemonPlistPath)"
    /bin/rm -f "\(HelperConstants.helperInstallPath)"
    /bin/rm -f "\(HelperConstants.socketPath)"
    /bin/rm -f "\(HelperConstants.cliInstallPath)"
    echo "UNINSTALLED"
    """
  }

  static func runAdminShellScript(_ script: String) -> Result<String, Error> {
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("wattwhat-admin-\(UUID().uuidString).sh")
    do {
      try script.write(to: tempURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
    } catch {
      return .failure(error)
    }
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let escaped = tempURL.path.replacingOccurrences(of: "\"", with: "\\\"")
    let appleScript = "do shell script \"/bin/bash \\\"\(escaped)\\\"\" with administrator privileges"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", appleScript]
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
      try process.run()
      process.waitUntilExit()
      let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      if process.terminationStatus == 0 {
        return .success(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      let message = stderr.isEmpty ? stdout : stderr
      return .failure(
        NSError(
          domain: "WattWhatAdmin", code: Int(process.terminationStatus),
          userInfo: [
            NSLocalizedDescriptionKey: message.isEmpty
              ? "Yönetici izni iptal edildi veya başarısız oldu."
              : message.trimmingCharacters(in: .whitespacesAndNewlines)
          ]))
    } catch {
      return .failure(error)
    }
  }

  static func installWithAdminPrompt() -> Result<String, Error> {
    let sourceDir = bundleExecutableDirectory()
    return runAdminShellScript(installShellScript(sourceDir: sourceDir))
  }

  static func uninstallWithAdminPrompt() -> Result<String, Error> {
    _ = HelperIPCClient.send(HelperRequest(command: .uninstallCleanup), timeoutSeconds: 1.5)
    return runAdminShellScript(uninstallShellScript())
  }
}
