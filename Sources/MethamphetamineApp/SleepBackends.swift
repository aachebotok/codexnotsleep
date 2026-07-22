import Foundation
import IOKit.pwr_mgt
import MethamphetamineCore

enum BackendError: LocalizedError {
  case assertionFailed(IOReturn)

  var errorDescription: String? {
    switch self {
    case .assertionFailed(let code):
      "Не удалось запретить автоматический сон: \(code)"
    }
  }
}

@MainActor
final class IdleSleepAssertionBackend: SleepProtectionBackend {
  let identifier = "IOPM idle-sleep assertion"
  private(set) var isHeld = false
  private var assertionID = IOPMAssertionID(0)

  func acquire() throws {
    guard !isHeld else { return }

    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      "Methamphetamine: supported coding agent is running" as CFString,
      &assertionID
    )
    guard result == kIOReturnSuccess else {
      throw BackendError.assertionFailed(result)
    }
    isHeld = true
  }

  func renew() throws {}

  func release() throws {
    guard isHeld else { return }
    IOPMAssertionRelease(assertionID)
    assertionID = 0
    isHeld = false
  }
}
