import Foundation
import IOKit.ps
import Testing

@testable import CodexNotSleepApp

@Suite
struct BatteryStatusProviderTests {
  @Test
  func parsesInternalBatteryCapacityWithoutRoundingTheThreshold() throws {
    let status = try #require(
      IOKitBatteryStatusProvider.status(
        from: [
          kIOPSTypeKey: kIOPSInternalBatteryType,
          kIOPSIsPresentKey: true,
          kIOPSCurrentCapacityKey: 19,
          kIOPSMaxCapacityKey: 200,
        ],
        isRunningOnBattery: true
      )
    )

    #expect(status.chargePercent == 9.5)
    #expect(status.isAtOrBelow(10))
  }

  @Test
  func exactThresholdCountsAsLowBatteryOnlyWhileRunningOnBattery() throws {
    let onBattery = BatteryStatus(chargePercent: 10, isRunningOnBattery: true)
    let onExternalPower = BatteryStatus(chargePercent: 9, isRunningOnBattery: false)

    #expect(onBattery.isAtOrBelow(10))
    #expect(!onExternalPower.isAtOrBelow(10))
  }

  @Test
  func ignoresUPSAbsentBatteryAndInvalidCapacity() {
    #expect(
      IOKitBatteryStatusProvider.status(
        from: [
          kIOPSTypeKey: kIOPSUPSType,
          kIOPSCurrentCapacityKey: 5,
          kIOPSMaxCapacityKey: 100,
        ],
        isRunningOnBattery: true
      ) == nil
    )
    #expect(
      IOKitBatteryStatusProvider.status(
        from: [
          kIOPSTypeKey: kIOPSInternalBatteryType,
          kIOPSIsPresentKey: false,
          kIOPSCurrentCapacityKey: 5,
          kIOPSMaxCapacityKey: 100,
        ],
        isRunningOnBattery: true
      ) == nil
    )
    #expect(
      IOKitBatteryStatusProvider.status(
        from: [
          kIOPSTypeKey: kIOPSInternalBatteryType,
          kIOPSCurrentCapacityKey: 5,
          kIOPSMaxCapacityKey: 0,
        ],
        isRunningOnBattery: true
      ) == nil
    )
  }
}
