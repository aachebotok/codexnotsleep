import Foundation
import IOKit.ps

struct BatteryStatus: Equatable, Sendable {
  let chargePercent: Double
  let isRunningOnBattery: Bool

  func isAtOrBelow(_ thresholdPercent: Double) -> Bool {
    isRunningOnBattery && chargePercent <= thresholdPercent
  }
}

protocol BatteryStatusProviding: Sendable {
  func currentStatus() -> BatteryStatus?
  func startMonitoring(onChange: @escaping @Sendable () -> Void)
  func stopMonitoring()
}

extension BatteryStatusProviding {
  func startMonitoring(onChange: @escaping @Sendable () -> Void) {}
  func stopMonitoring() {}
}

final class IOKitBatteryStatusProvider: BatteryStatusProviding, @unchecked Sendable {
  private let readStatus: @Sendable () -> BatteryStatus?
  private let lock = NSLock()
  private var cachedStatus: BatteryStatus?
  private var cacheIsValid = false
  private var notificationSource: CFRunLoopSource?
  private var changeHandler: (@Sendable () -> Void)?

  init(
    readStatus: @escaping @Sendable () -> BatteryStatus? = IOKitBatteryStatusProvider
      .readCurrentStatus
  ) {
    self.readStatus = readStatus
  }

  func currentStatus() -> BatteryStatus? {
    let cached = lock.withLock { (cacheIsValid, cachedStatus) }
    if cached.0 {
      return cached.1
    }

    let status = readStatus()
    lock.withLock {
      cachedStatus = status
      cacheIsValid = true
    }
    return status
  }

  func startMonitoring(onChange: @escaping @Sendable () -> Void) {
    let shouldInstall = lock.withLock { () -> Bool in
      changeHandler = onChange
      return notificationSource == nil
    }
    guard shouldInstall else { return }

    guard
      let unmanagedSource = IOPSNotificationCreateRunLoopSource(
        Self.notificationCallback,
        Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      return
    }
    let source = unmanagedSource.takeRetainedValue()
    lock.withLock { notificationSource = source }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
  }

  func stopMonitoring() {
    let source = lock.withLock { () -> CFRunLoopSource? in
      changeHandler = nil
      let source = notificationSource
      notificationSource = nil
      return source
    }
    if let source {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
  }

  func invalidateCacheForTesting() {
    handlePowerSourceChange()
  }

  private func handlePowerSourceChange() {
    let handler = lock.withLock { () -> (@Sendable () -> Void)? in
      cacheIsValid = false
      return changeHandler
    }
    handler?()
  }

  private static let notificationCallback: IOPowerSourceCallbackType = { context in
    guard let context else { return }
    let provider = Unmanaged<IOKitBatteryStatusProvider>
      .fromOpaque(context)
      .takeUnretainedValue()
    provider.handlePowerSourceChange()
  }

  private static func readCurrentStatus() -> BatteryStatus? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
      return nil
    }

    let isRunningOnBattery =
      IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
      == kIOPMBatteryPowerKey

    guard
      let powerSources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
        as? [CFTypeRef]
    else {
      return nil
    }

    for powerSource in powerSources {
      guard
        let description = IOPSGetPowerSourceDescription(snapshot, powerSource)?
          .takeUnretainedValue() as? [String: Any],
        let status = status(
          from: description,
          isRunningOnBattery: isRunningOnBattery
        )
      else { continue }

      return status
    }

    return nil
  }

  static func status(
    from description: [String: Any],
    isRunningOnBattery: Bool
  ) -> BatteryStatus? {
    guard
      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
      description[kIOPSIsPresentKey] as? Bool != false,
      let chargePercent = chargePercent(from: description)
    else {
      return nil
    }

    return BatteryStatus(
      chargePercent: chargePercent,
      isRunningOnBattery: isRunningOnBattery
    )
  }

  static func chargePercent(from description: [String: Any]) -> Double? {
    guard
      let currentCapacity = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
      let maxCapacity = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
      currentCapacity >= 0,
      maxCapacity > 0
    else {
      return nil
    }

    return min(max(currentCapacity / maxCapacity * 100, 0), 100)
  }
}
