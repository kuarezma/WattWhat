import Foundation
import IOKit

public struct SMCKeyDiagnostic: Codable, Equatable, Identifiable, Sendable {
  public var id: String { key }
  public let key: String
  public let dataType: String
  public let dataSize: UInt32
  public let attributes: UInt8
  public let currentHex: String
  public let numericSummary: String
  public let lastWriteResult: String?

  public init(
    key: String,
    dataType: String,
    dataSize: UInt32,
    attributes: UInt8,
    currentHex: String,
    numericSummary: String,
    lastWriteResult: String?
  ) {
    self.key = key
    self.dataType = dataType
    self.dataSize = dataSize
    self.attributes = attributes
    self.currentHex = currentHex
    self.numericSummary = numericSummary
    self.lastWriteResult = lastWriteResult
  }

  public var isWritableFlag: Bool {
    (attributes & 0x40) != 0
  }

  public var isReadableFlag: Bool {
    (attributes & 0x80) != 0
  }
}

public struct SMCBaselineSnapshot: Codable, Equatable, Sendable {
  public let capturedAt: Date
  public var keys: [String: [UInt8]]

  public init(capturedAt: Date, keys: [String: [UInt8]]) {
    self.capturedAt = capturedAt
    self.keys = keys
  }
}

public enum AppleSMCError: Error, LocalizedError, Sendable {
  case serviceNotFound
  case openFailed(kern_return_t)
  case callFailed(key: String, kernReturn: kern_return_t, smcResult: UInt8)
  case keyNotFound(String)
  case keyNotReadable(String)
  case invalidDataSize(key: String, expected: UInt32, actual: Int)

  public var errorDescription: String? {
    switch self {
    case .serviceNotFound:
      return "AppleSMC servisi bulunamadı."
    case .openFailed(let kr):
      return "AppleSMC bağlantısı açılamadı (kern_return=\(kr))."
    case .callFailed(let key, let kr, let res):
      return "SMC işlemi başarısız (\(key): kr=\(kr), smcResult=\(res))."
    case .keyNotFound(let key):
      return "SMC anahtarı bulunamadı: \(key)"
    case .keyNotReadable(let key):
      return "SMC anahtarı okunabilir değil (salt-yazılır): \(key)"
    case .invalidDataSize(let key, let expected, let actual):
      return "SMC boyut uyumsuzluğu (\(key): beklenen \(expected), gelen \(actual))."
    }
  }
}

public final class AppleSMCClient: @unchecked Sendable {
  public struct SMCKeyDataVersion {
    public var major: UInt8 = 0
    public var minor: UInt8 = 0
    public var build: UInt8 = 0
    public var reserved: UInt8 = 0
    public var release: UInt16 = 0

    public init() {}
  }

  public struct SMCPLimitData {
    public var version: UInt16 = 0
    public var length: UInt16 = 0
    public var cpuPLimit: UInt32 = 0
    public var gpuPLimit: UInt32 = 0
    public var memPLimit: UInt32 = 0

    public init() {}
  }

  public struct SMCKeyInfoData {
    public var dataSize: UInt32 = 0
    public var dataType: UInt32 = 0
    public var dataAttributes: UInt8 = 0

    public init() {}
  }

  public typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
  )

  public struct SMCKeyData {
    public var key: UInt32 = 0
    public var vers = SMCKeyDataVersion()
    public var pLimitData = SMCPLimitData()
    public var keyInfo = SMCKeyInfoData()
    public var padding: UInt16 = 0
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: SMCBytes = (
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )

    public init() {}
  }

  private static let kSMCUserClientOpen: UInt32 = 0
  private static let kSMCUserClientClose: UInt32 = 1
  private static let kSMCHandleYPCEvent: UInt32 = 2
  private static let kSMCReadKey: UInt8 = 5
  private static let kSMCWriteKey: UInt8 = 6
  private static let kSMCGetKeyInfo: UInt8 = 9

  /// M1/M2/M3 Apple Silicon cihazlarda ilgili şarj/güç SMC anahtarları.
  public static let knownPowerAndChargerKeys: [String] = [
    "BTIL", "BTSI", "BTVL", "BTSV",
    "CIPW", "CIPR", "CIPI", "CIPP", "CIPV", "CIP0", "CIPC",
    "CHAS", "CHA1", "CHA2", "CHAI",
    "CHI1", "CHI2", "ACLM", "ACPW",
    "CHIL", "CHCE", "CHIE", "CHLT", "ACLC",
    "CH0B", "CH0C", "CHTE", "CH0I", "CH0J",
    "D1BI", "D2BI", "D3BI", "UB0C",
    "bfG0", "bfI0", "bfJ0", "bfK0", "bfL0",
  ]

  public static let controlledKeysForBaseline: [String] = [
    "CHIE", "D1BI", "D2BI", "D3BI",
  ]

  private var connection: io_connect_t = 0
  private var service: io_service_t = 0

  public init() throws {
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

  public static func toFourCC(_ key: String) -> UInt32 {
    key.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
  }

  public static func fromFourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
    return String(bytes.map { byte in
      let scalar = UnicodeScalar(byte)
      return (byte >= 32 && byte < 127) ? Character(scalar) : "?"
    })
  }

  public static func encodeUInt32LE(_ value: UInt32) -> [UInt8] {
    [
      UInt8(value & 0xFF),
      UInt8((value >> 8) & 0xFF),
      UInt8((value >> 16) & 0xFF),
      UInt8((value >> 24) & 0xFF),
    ]
  }

  public static func decodeUInt32LE(_ bytes: [UInt8]) -> UInt32? {
    guard bytes.count >= 4 else { return nil }
    return UInt32(bytes[0])
      | (UInt32(bytes[1]) << 8)
      | (UInt32(bytes[2]) << 16)
      | (UInt32(bytes[3]) << 24)
  }

  public static func encodeUInt16LE(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
  }

  public static func decodeUInt16LE(_ bytes: [UInt8]) -> UInt16? {
    guard bytes.count >= 2 else { return nil }
    return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
  }

  public static func decodeFloatLE(_ bytes: [UInt8]) -> Float? {
    guard let bits = decodeUInt32LE(bytes) else { return nil }
    return Float(bitPattern: bits)
  }

  public static func formatNumericSummary(dataType: String, bytes: [UInt8]) -> String {
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

  public func keyInfo(for key: String) throws -> (dataSize: UInt32, dataType: String, attributes: UInt8) {
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

  public func readKey(_ key: String) throws -> (bytes: [UInt8], dataType: String, attributes: UInt8) {
    let info = try keyInfo(for: key)
    guard (info.attributes & 0x80) != 0 else {
      throw AppleSMCError.keyNotReadable(key)
    }
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

  public func writeKey(_ key: String, bytes: [UInt8]) throws {
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

  public func writeUInt32LE(_ key: String, value: UInt32) throws {
    try writeKey(key, bytes: Self.encodeUInt32LE(value))
  }

  public func writeUInt8(_ key: String, value: UInt8) throws {
    try writeKey(key, bytes: [value])
  }

  public func readUInt32LE(_ key: String) throws -> UInt32 {
    let result = try readKey(key)
    guard let decoded = Self.decodeUInt32LE(result.bytes) else {
      throw AppleSMCError.invalidDataSize(key: key, expected: 4, actual: result.bytes.count)
    }
    return decoded
  }

  public func captureBaseline(keys: [String] = AppleSMCClient.controlledKeysForBaseline) -> SMCBaselineSnapshot {
    var map: [String: [UInt8]] = [:]
    for key in keys {
      guard let info = try? keyInfo(for: key), (info.attributes & 0xc0) == 0xc0 else {
        continue
      }
      if let read = try? readKey(key) {
        map[key] = read.bytes
      }
    }
    return SMCBaselineSnapshot(capturedAt: Date(), keys: map)
  }

  public func restoreBaseline(_ snapshot: SMCBaselineSnapshot) -> [String: String] {
    var results: [String: String] = [:]
    for (key, bytes) in snapshot.keys {
      do {
        let info = try keyInfo(for: key)
        if key == "ACLC" {
          guard (info.attributes & 0x40) != 0 else {
            results[key] = "Atlandı (salt-okunur)"
            continue
          }
          try writeKey(key, bytes: [0x00])
          results[key] = "OK"
          continue
        }
        guard (info.attributes & 0xc0) == 0xc0 else {
          results[key] = "Atlandı (salt-okunur)"
          continue
        }
        try writeKey(key, bytes: bytes)
        results[key] = "OK"
      } catch {
        results[key] = error.localizedDescription
      }
    }
    return results
  }

  public static func baselineContainsLegacyReadOnlyKeys(_ snapshot: SMCBaselineSnapshot) -> Bool {
    snapshot.keys.keys.contains(where: { ["BTIL", "CHIL", "CHCE", "CIPW", "ACLC"].contains($0) })
  }

  public static func probeReadableChargerKeys(lastWriteResults: [String: String] = [:]) -> [SMCKeyDiagnostic] {
    guard let client = try? AppleSMCClient() else { return [] }
    return knownPowerAndChargerKeys.compactMap { key in
      guard let info = try? client.keyInfo(for: key) else { return nil }
      if (info.attributes & 0x80) == 0 {
        return SMCKeyDiagnostic(
          key: key,
          dataType: info.dataType,
          dataSize: info.dataSize,
          attributes: info.attributes,
          currentHex: "(write-only)",
          numericSummary: "salt-yazılır",
          lastWriteResult: lastWriteResults[key]
        )
      }
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
