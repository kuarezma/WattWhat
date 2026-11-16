import Darwin
import Foundation
import ObjectiveC

@_silgen_name("notify_post")
private func darwinNotifyPost(_ name: UnsafePointer<CChar>) -> UInt32

public struct PowerUIState: Codable, Equatable, Sendable {
  public let isSupported: Bool
  public let isEnabled: Bool
  public let currentLimit: Int

  public init(isSupported: Bool, isEnabled: Bool, currentLimit: Int) {
    self.isSupported = isSupported
    self.isEnabled = isEnabled
    self.currentLimit = currentLimit
  }
}

public final class PowerUIBridge: @unchecked Sendable {
  public static let shared = PowerUIBridge()

  private static let frameworkPath =
    "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"
  private static let smartChargeDomain = "com.apple.smartcharging.topoffprotection"
  private static let defaultsChangedNotification = "com.apple.smartcharging.defaultschanged"

  private let lock = NSRecursiveLock()
  private let clientClass: AnyClass?
  private let client: AnyObject?

  private init() {
    _ = dlopen(Self.frameworkPath, RTLD_NOW)
    guard let cls = NSClassFromString("PowerUISmartChargeClient") else {
      self.clientClass = nil
      self.client = nil
      return
    }
    self.clientClass = cls

    let allocSel = NSSelectorFromString("alloc")
    let initSel = NSSelectorFromString("initWithClientName:")
    guard
      let allocMethod = class_getClassMethod(cls, allocSel),
      class_getInstanceMethod(cls, initSel) != nil,
      let initIMPAddr = class_getMethodImplementation(cls, initSel)
    else {
      self.client = nil
      return
    }

    let allocIMP = unsafeBitCast(
      method_getImplementation(allocMethod),
      to: (@convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?).self
    )
    let initIMP = unsafeBitCast(
      initIMPAddr,
      to: (@convention(c) (Unmanaged<AnyObject>, Selector, NSString) -> Unmanaged<AnyObject>?).self
    )

    guard let allocated = allocIMP(cls, allocSel) else {
      self.client = nil
      return
    }
    self.client = initIMP(allocated, initSel, "WattWhat" as NSString)?.takeRetainedValue()
  }

  public var isSupported: Bool {
    lock.lock()
    defer { lock.unlock() }

    guard let cls = clientClass, let client else { return false }
    let sel = NSSelectorFromString("isMCLSupported")
    guard
      client.responds(to: sel),
      class_getInstanceMethod(cls, sel) != nil,
      let impAddr = class_getMethodImplementation(cls, sel)
    else {
      return false
    }
    let imp = unsafeBitCast(
      impAddr,
      to: (@convention(c) (AnyObject, Selector) -> Bool).self
    )
    return imp(client, sel)
  }

  public func readState() -> PowerUIState {
    lock.lock()
    defer { lock.unlock() }

    guard isSupported, let cls = clientClass, let client else {
      return PowerUIState(isSupported: false, isEnabled: false, currentLimit: 100)
    }

    if geteuid() == 0 {
      let domain = Self.smartChargeDomain as CFString
      CFPreferencesSynchronize(
        domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
      let featureState =
        CFPreferencesCopyValue(
          "MCLFeatureState" as CFString,
          domain,
          kCFPreferencesCurrentUser,
          kCFPreferencesAnyHost
        ) as? NSNumber
      let limitPref =
        CFPreferencesCopyValue(
          "mclLimitValue" as CFString,
          domain,
          kCFPreferencesCurrentUser,
          kCFPreferencesAnyHost
        ) as? NSNumber
      if let featureState, let limitPref {
        let enabled = featureState.intValue != 0
        let limit = min(max(limitPref.intValue, 1), 100)
        return PowerUIState(isSupported: true, isEnabled: enabled, currentLimit: limit)
      }
    }

    let limit = readLimitFromClient(cls: cls, client: client) ?? 100
    let enabled = readEnabledFromClient(cls: cls, client: client) ?? false
    let resolvedLimit = limit == 0 ? 100 : min(max(limit, 1), 100)
    return PowerUIState(isSupported: true, isEnabled: enabled, currentLimit: resolvedLimit)
  }

  public func setExactChargeLimit(_ limit: Int) -> Result<Void, Error> {
    lock.lock()
    defer { lock.unlock() }

    if limit >= 100 {
      return disableChargeLimit()
    }

    guard isSupported, let cls = clientClass, let client else {
      return .failure(Self.unsupportedError())
    }

    let clampedLimit = min(max(limit, 1), 99)

    if geteuid() == 0 {
      writeRootSmartChargePrefs(featureState: 1, limitValue: clampedLimit)
    }

    if [80, 85, 90, 95].contains(clampedLimit) {
      let setSel = NSSelectorFromString("setMCLLimit:error:")
      if client.responds(to: setSel),
        class_getInstanceMethod(cls, setSel) != nil,
        let impAddr = class_getMethodImplementation(cls, setSel)
      {
        if case .failure(let error) = callSetLimit(
          client: client, selector: setSel, impAddr: impAddr, limit: UInt8(clampedLimit))
        {
          return .failure(error)
        }
      }
    }

    let enableSel = NSSelectorFromString("enableMCL:")
    if client.responds(to: enableSel),
      class_getInstanceMethod(cls, enableSel) != nil,
      let impAddr = class_getMethodImplementation(cls, enableSel)
    {
      return callBoolWithError(client: client, selector: enableSel, impAddr: impAddr)
    }

    return .success(())
  }

  public func holdChargingNow(currentBatteryPercent: Double) -> Result<Void, Error> {
    let holdTarget = min(max(Int(currentBatteryPercent.rounded(.down)), 10), 99)
    return setExactChargeLimit(holdTarget)
  }

  public func disableChargeLimit() -> Result<Void, Error> {
    lock.lock()
    defer { lock.unlock() }

    guard isSupported, let cls = clientClass, let client else {
      return .failure(Self.unsupportedError())
    }

    if geteuid() == 0 {
      writeRootSmartChargePrefs(featureState: 0, limitValue: 100)
    }

    let disableSel = NSSelectorFromString("disableMCL:")
    guard
      client.responds(to: disableSel),
      class_getInstanceMethod(cls, disableSel) != nil,
      let impAddr = class_getMethodImplementation(cls, disableSel)
    else {
      return .failure(Self.selectorUnavailableError("disableMCL:"))
    }

    return callBoolWithError(client: client, selector: disableSel, impAddr: impAddr)
  }

  public func enableTemporaryTopUpTo100() -> Result<Void, Error> {
    lock.lock()
    defer { lock.unlock() }

    if let cls = clientClass, let client {
      let tempSel = NSSelectorFromString("temporarilyDisableMCL:")
      if client.responds(to: tempSel),
        class_getInstanceMethod(cls, tempSel) != nil,
        let impAddr = class_getMethodImplementation(cls, tempSel)
      {
        if case .success = callBoolWithError(client: client, selector: tempSel, impAddr: impAddr) {
          return .success(())
        }
      }
    }
    return disableChargeLimit()
  }

  private func writeRootSmartChargePrefs(featureState: Int, limitValue: Int) {
    let domain = Self.smartChargeDomain as CFString
    CFPreferencesSetValue(
      "MCLFeatureState" as CFString,
      NSNumber(value: featureState),
      domain,
      kCFPreferencesCurrentUser,
      kCFPreferencesAnyHost
    )
    CFPreferencesSetValue(
      "mclLimitValue" as CFString,
      NSNumber(value: limitValue),
      domain,
      kCFPreferencesCurrentUser,
      kCFPreferencesAnyHost
    )
    CFPreferencesSynchronize(
      domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    _ = Self.defaultsChangedNotification.withCString { darwinNotifyPost($0) }
  }

  private func readLimitFromClient(cls: AnyClass, client: AnyObject) -> Int? {
    let sel = NSSelectorFromString("getMCLLimitWithError:")
    guard
      client.responds(to: sel),
      class_getInstanceMethod(cls, sel) != nil,
      let impAddr = class_getMethodImplementation(cls, sel)
    else {
      return nil
    }
    let imp = unsafeBitCast(
      impAddr,
      to: (@convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> UInt8).self
    )
    return autoreleasepool {
      var rawError: Unmanaged<NSError>?
      let value = withUnsafeMutablePointer(to: &rawError) { imp(client, sel, $0) }
      if rawError != nil {
        return nil
      }
      return Int(value)
    }
  }

  private func readEnabledFromClient(cls: AnyClass, client: AnyObject) -> Bool? {
    let sel = NSSelectorFromString("isMCLCurrentlyEnabled:")
    guard
      client.responds(to: sel),
      class_getInstanceMethod(cls, sel) != nil,
      let impAddr = class_getMethodImplementation(cls, sel)
    else {
      return nil
    }
    let imp = unsafeBitCast(
      impAddr,
      to: (@convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> UInt64).self
    )
    return autoreleasepool {
      var rawError: Unmanaged<NSError>?
      let value = withUnsafeMutablePointer(to: &rawError) { imp(client, sel, $0) }
      if rawError != nil {
        return nil
      }
      return value != 0
    }
  }

  private func callSetLimit(
    client: AnyObject,
    selector: Selector,
    impAddr: IMP,
    limit: UInt8
  ) -> Result<Void, Error> {
    let imp = unsafeBitCast(
      impAddr,
      to: (@convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool).self
    )
    return autoreleasepool {
      var rawError: Unmanaged<NSError>?
      let ok = withUnsafeMutablePointer(to: &rawError) { imp(client, selector, limit, $0) }
      if ok {
        return .success(())
      }
      let err = rawError?.takeUnretainedValue() ?? Self.callFailedError("setMCLLimit:error:")
      return .failure(err)
    }
  }

  private func callBoolWithError(
    client: AnyObject,
    selector: Selector,
    impAddr: IMP
  ) -> Result<Void, Error> {
    let imp = unsafeBitCast(
      impAddr,
      to: (@convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool).self
    )
    return autoreleasepool {
      var rawError: Unmanaged<NSError>?
      let ok = withUnsafeMutablePointer(to: &rawError) { imp(client, selector, $0) }
      if ok {
        return .success(())
      }
      let err = rawError?.takeUnretainedValue() ?? Self.callFailedError(NSStringFromSelector(selector))
      return .failure(err)
    }
  }

  private static func unsupportedError() -> NSError {
    NSError(
      domain: "WattWhatPowerUI",
      code: -1,
      userInfo: [NSLocalizedDescriptionKey: "PowerUI şarj limiti bu cihazda desteklenmiyor."]
    )
  }

  private static func selectorUnavailableError(_ name: String) -> NSError {
    NSError(
      domain: "WattWhatPowerUI",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "PowerUI seçicisi bulunamadı: \(name)"]
    )
  }

  private static func callFailedError(_ name: String) -> NSError {
    NSError(
      domain: "WattWhatPowerUI",
      code: -3,
      userInfo: [NSLocalizedDescriptionKey: "PowerUI çağrısı başarısız: \(name)"]
    )
  }
}
