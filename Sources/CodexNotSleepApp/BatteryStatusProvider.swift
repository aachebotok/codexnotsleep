import Foundation
import IOKit.ps

struct BatteryStatus: Equatable, Sendable {
  let chargePercent: Double
  let isRunningOnBattery: Bool

  func isAtOrBelow(_ thresholdPercent: Double) -> Bool {
    isRunningOnBattery && chargePercent <= thresholdPercent
  }
}

protocol BatteryStatusProviding {
  func currentStatus() -> BatteryStatus?
}

struct IOKitBatteryStatusProvider: BatteryStatusProviding {
  func currentStatus() -> BatteryStatus? {
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
        let status = Self.status(
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
