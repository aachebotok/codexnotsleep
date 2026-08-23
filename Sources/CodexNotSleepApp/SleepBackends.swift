import CodexNotSleepCore
import Foundation
import IOKit.pwr_mgt

enum BackendError: LocalizedError {
  case assertionFailed(IOReturn)
  case assertionReleaseFailed(IOReturn)

  var errorDescription: String? {
    switch self {
    case .assertionFailed(let code):
      "Couldn't prevent automatic sleep: \(code)"
    case .assertionReleaseFailed(let code):
      "Couldn't release automatic sleep protection: \(code)"
    }
  }
}

protocol IOPMAssertionManaging {
  func createPreventUserIdleSystemSleep(
    name: String,
    assertionID: UnsafeMutablePointer<IOPMAssertionID>
  ) -> IOReturn
  func release(_ assertionID: IOPMAssertionID) -> IOReturn
}

struct SystemIOPMAssertionManager: IOPMAssertionManaging {
  func createPreventUserIdleSystemSleep(
    name: String,
    assertionID: UnsafeMutablePointer<IOPMAssertionID>
  ) -> IOReturn {
    IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      name as CFString,
      assertionID
    )
  }

  func release(_ assertionID: IOPMAssertionID) -> IOReturn {
    IOPMAssertionRelease(assertionID)
  }
}

final class IdleSleepAssertionBackend: SleepProtectionBackend {
  let identifier = "IOPM idle-sleep assertion"
  private(set) var isHeld = false
  private var assertionID = IOPMAssertionID(0)
  private let assertionManager: any IOPMAssertionManaging

  init(assertionManager: any IOPMAssertionManaging = SystemIOPMAssertionManager()) {
    self.assertionManager = assertionManager
  }

  func acquire() throws {
    guard !isHeld else { return }

    let result = assertionManager.createPreventUserIdleSystemSleep(
      name: "Codexetine: supported coding agent is running",
      assertionID: &assertionID
    )
    guard result == kIOReturnSuccess else {
      throw BackendError.assertionFailed(result)
    }
    isHeld = true
  }

  func renew() throws {}

  func release() throws {
    guard isHeld else { return }
    let result = assertionManager.release(assertionID)
    guard result == kIOReturnSuccess else {
      throw BackendError.assertionReleaseFailed(result)
    }
    assertionID = 0
    isHeld = false
  }
}
