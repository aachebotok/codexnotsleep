import Foundation
import IOKit.ps
import Testing

@testable import MethamphetamineApp

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
    #expect(status.isBelow(10))
  }

  @Test
  func exactThresholdAndExternalPowerDoNotCountAsLowBattery() throws {
    let onBattery = BatteryStatus(chargePercent: 10, isRunningOnBattery: true)
    let onExternalPower = BatteryStatus(chargePercent: 9, isRunningOnBattery: false)

    #expect(!onBattery.isBelow(10))
    #expect(!onExternalPower.isBelow(10))
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
