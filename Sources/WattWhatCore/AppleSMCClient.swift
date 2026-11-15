import Foundation
import IOKit

struct SMCKeyDiagnostic: Codable, Equatable, Identifiable, Sendable {
  var id: String { key }
  let key: String
  let dataType: String
  let dataSize: UInt32
  let attributes: UInt8
  let currentHex: String
  let numericSummary: String
  let lastWriteResult: String?

  var isWritableFlag: Bool {
    (attributes & 0x10) != 0
  }
}

struct SMCBaselineSnapshot: Codable, Equatable, Sendable {
  let capturedAt: Date
  var keys: [String: [UInt8]]
}

enum AppleSMCError: Error, LocalizedError, Sendable {
  case serviceNotFound
  case openFailed(kern_return_t)
  case callFailed(key: String, kernReturn: kern_return_t, smcResult: UInt8)
  case keyNotFound(String)
  case invalidDataSize(key: String, expected: UInt32, actual: Int)

  var errorDescription: String? {
    switch self {
    case .serviceNotFound:
      return "AppleSMC servisi bulunamadı."
    case .openFailed(let kr):
      return "AppleSMC bağlantısı açılamadı (kern_return=\(kr))."
    case .callFailed(let key, let kr, let res):
      return "SMC işlemi başarısız (\(key): kr=\(kr), smcResult=\(res))."
    case .keyNotFound(let key):
      return "SMC anahtarı bulunamadı: \(key)"
    case .invalidDataSize(let key, let expected, let actual):
      return "SMC boyut uyumsuzluğu (\(key): beklenen \(expected), gelen \(actual))."
    }
  }
}

final class AppleSMCClient: @unchecked Sendable {
  struct SMCKeyDataVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
  }

  struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
  }

  struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
  }

  typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
  )

  struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
  }

  private static let kSMCUserClientOpen: UInt32 = 0
  private static let kSMCUserClientClose: UInt32 = 1
  private static let kSMCHandleYPCEvent: UInt32 = 2
  private static let kSMCReadKey: UInt8 = 5
  private static let kSMCWriteKey: UInt8 = 6
  private static let kSMCGetKeyInfo: UInt8 = 9

  /// M1/M2/M3 Apple Silicon cihazlarda ilgili şarj/güç SMC anahtarları.
  static let knownPowerAndChargerKeys: [String] = [
    "BTIL", "BTSI", "BTVL", "BTSV",
    "CIPW", "CIPR", "CIPI", "CIPP", "CIPV", "CIP0", "CIPC",
    "CHAS", "CHA1", "CHA2", "CHAI",
    "CHI1", "CHI2", "ACLM", "ACPW",
    "CHIL", "CHCE", "CHIE", "CHLT", "ACLC",
    "CH0B", "CH0C", "CHTE", "CH0I", "CH0J",
    "bfG0", "bfI0", "bfJ0", "bfK0", "bfL0",
  ]

  static let controlledKeysForBaseline: [String] = [
    "BTIL", "BTSI",
    "CIPW", "CIPR", "CIPI",
    "CHAS", "CHA1", "CHA2", "CHAI",
    "CHI1", "CHI2", "ACLM",
    "CHIL", "CHCE", "CHIE", "CHLT", "ACLC",
    "CH0B", "CH0C", "CHTE",
  ]

  private var connection: io_connect_t = 0
  private var service: io_service_t = 0

  init() throws {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard svc != 0 else {
      throw AppleSMCError.serviceNotFound
    }
    var conn: io_connect_t = 0
    let kr = IOServiceOpen(svc, mach_task_self_, 0, &conn)
    guard kr == KERN_SUCCESS else {
      IOObjectRelease(svc)
      throw AppleSMCError.openFailed(kr)
    }
    self.service = svc
    self.connection = conn
  }

  deinit {
    if connection != 0 {
      IOServiceClose(connection)
    }
    if service != 0 {
      IOObjectRelease(service)
    }
  }

  static func toFourCC(_ key: String) -> UInt32 {
    key.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
  }

  static func fromFourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
    return String(bytes.map { byte in
      let scalar = UnicodeScalar(byte)
      return (byte >= 32 && byte < 127) ? Character(scalar) : "?"
    })
  }

  static func encodeUInt32LE(_ value: UInt32) -> [UInt8] {
    [
      UInt8(value & 0xFF),
      UInt8((value >> 8) & 0xFF),
      UInt8((value >> 16) & 0xFF),
      UInt8((value >> 24) & 0xFF),
    ]
  }

  static func decodeUInt32LE(_ bytes: [UInt8]) -> UInt32? {
    guard bytes.count >= 4 else { return nil }
    return UInt32(bytes[0])
      | (UInt32(bytes[1]) << 8)
      | (UInt32(bytes[2]) << 16)
      | (UInt32(bytes[3]) << 24)
  }

  static func encodeUInt16LE(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
  }

  static func decodeUInt16LE(_ bytes: [UInt8]) -> UInt16? {
    guard bytes.count >= 2 else { return nil }
    return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
  }

  static func decodeFloatLE(_ bytes: [UInt8]) -> Float? {
    guard let bits = decodeUInt32LE(bytes) else { return nil }
    return Float(bitPattern: bits)
  }

  static func formatNumericSummary(dataType: String, bytes: [UInt8]) -> String {
    let trimmed = dataType.trimmingCharacters(in: .whitespaces)
    switch trimmed {
    case "ui8", "flag":
      if let b = bytes.first { return "\(b)" }
    case "ui16":
      if let v = decodeUInt16LE(bytes) { return "\(v)" }
    case "ui32":
      if let v = decodeUInt32LE(bytes) { return "\(v)" }
    case "si32":
      if let v = decodeUInt32LE(bytes) { return "\(Int32(bitPattern: v))" }
    case "flt":
      if let f = decodeFloatLE(bytes) { return String(format: "%.3f", f) }
    default:
      break
    }
    return bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
  }

  private func callSMC(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
    var outSize = MemoryLayout<SMCKeyData>.size
    return IOConnectCallStructMethod(
      connection,
      Self.kSMCHandleYPCEvent,
      &input,
      MemoryLayout<SMCKeyData>.size,
      &output,
      &outSize
    )
  }

  func keyInfo(for key: String) throws -> (dataSize: UInt32, dataType: String, attributes: UInt8) {
    var input = SMCKeyData()
    var output = SMCKeyData()
    input.key = Self.toFourCC(key)
    input.data8 = Self.kSMCGetKeyInfo
    let kr = callSMC(&input, &output)
    guard kr == KERN_SUCCESS else {
      throw AppleSMCError.callFailed(key: key, kernReturn: kr, smcResult: output.result)
    }
    guard output.result == 0 else {
      if output.result == 132 {
        throw AppleSMCError.keyNotFound(key)
      }
      throw AppleSMCError.callFailed(key: key, kernReturn: kr, smcResult: output.result)
    }
    return (
      dataSize: output.keyInfo.dataSize,
      dataType: Self.fromFourCC(output.keyInfo.dataType),
      attributes: output.keyInfo.dataAttributes
    )
  }

  func readKey(_ key: String) throws -> (bytes: [UInt8], dataType: String, attributes: UInt8) {
    let info = try keyInfo(for: key)
    guard info.dataSize > 0, info.dataSize <= 32 else {
      throw AppleSMCError.invalidDataSize(key: key, expected: info.dataSize, actual: 0)
    }
    var input = SMCKeyData()
    var output = SMCKeyData()
    input.key = Self.toFourCC(key)
    input.keyInfo.dataSize = info.dataSize
    input.data8 = Self.kSMCReadKey
    let kr = callSMC(&input, &output)
    guard kr == KERN_SUCCESS, output.result == 0 else {
      throw AppleSMCError.callFailed(key: key, kernReturn: kr, smcResult: output.result)
    }
    let bytes = withUnsafeBytes(of: output.bytes) { raw in
      Array(raw.prefix(Int(info.dataSize)))
    }
    return (bytes: bytes, dataType: info.dataType, attributes: info.attributes)
  }

  func writeKey(_ key: String, bytes: [UInt8]) throws {
    let info = try keyInfo(for: key)
    guard info.dataSize > 0, bytes.count == Int(info.dataSize) else {
      throw AppleSMCError.invalidDataSize(key: key, expected: info.dataSize, actual: bytes.count)
    }
    var input = SMCKeyData()
    var output = SMCKeyData()
    input.key = Self.toFourCC(key)
    input.keyInfo.dataSize = info.dataSize
    input.data8 = Self.kSMCWriteKey
    withUnsafeMutableBytes(of: &input.bytes) { dest in
      for (index, byte) in bytes.prefix(32).enumerated() {
        dest[index] = byte
      }
    }
    let kr = callSMC(&input, &output)
    guard kr == KERN_SUCCESS, output.result == 0 else {
      throw AppleSMCError.callFailed(key: key, kernReturn: kr, smcResult: output.result)
    }
  }

  func writeUInt32LE(_ key: String, value: UInt32) throws {
    try writeKey(key, bytes: Self.encodeUInt32LE(value))
  }

  func writeUInt8(_ key: String, value: UInt8) throws {
    try writeKey(key, bytes: [value])
  }

  func readUInt32LE(_ key: String) throws -> UInt32 {
    let result = try readKey(key)
    guard let decoded = Self.decodeUInt32LE(result.bytes) else {
      throw AppleSMCError.invalidDataSize(key: key, expected: 4, actual: result.bytes.count)
    }
    return decoded
  }

  func captureBaseline(keys: [String] = AppleSMCClient.controlledKeysForBaseline) -> SMCBaselineSnapshot {
    var map: [String: [UInt8]] = [:]
    for key in keys {
      if let read = try? readKey(key) {
        map[key] = read.bytes
      }
    }
    return SMCBaselineSnapshot(capturedAt: Date(), keys: map)
  }

  func restoreBaseline(_ snapshot: SMCBaselineSnapshot) -> [String: String] {
    var results: [String: String] = [:]
    for (key, bytes) in snapshot.keys {
      do {
        try writeKey(key, bytes: bytes)
        results[key] = "OK"
      } catch {
        results[key] = error.localizedDescription
      }
    }
    return results
  }

  static func probeReadableChargerKeys(lastWriteResults: [String: String] = [:]) -> [SMCKeyDiagnostic] {
    guard let client = try? AppleSMCClient() else { return [] }
    return knownPowerAndChargerKeys.compactMap { key in
      guard let res = try? client.readKey(key) else { return nil }
      let hex = res.bytes.map { String(format: "%02x", $0) }.joined()
      let summary = formatNumericSummary(dataType: res.dataType, bytes: res.bytes)
      return SMCKeyDiagnostic(
        key: key,
        dataType: res.dataType,
        dataSize: UInt32(res.bytes.count),
        attributes: res.attributes,
        currentHex: hex,
        numericSummary: summary,
        lastWriteResult: lastWriteResults[key]
      )
    }
  }
}
