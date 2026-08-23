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

/// The only sleep-protection operation safe to attempt synchronously during
/// external process termination. Implementations must not enter a worker
/// queue or run privileged closed-lid recovery.
protocol ExternalTerminationReleasing: AnyObject {
  func releaseForExternalTermination() throws
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

final class IdleSleepAssertionBackend: SleepProtectionBackend, ExternalTerminationReleasing {
  let identifier = "IOPM idle-sleep assertion"
  private let stateLock = NSLock()
  private var held = false
  private var assertionID = IOPMAssertionID(0)
  private let assertionManager: any IOPMAssertionManaging

  var isHeld: Bool {
    stateLock.withLock { held }
  }

  init(assertionManager: any IOPMAssertionManaging = SystemIOPMAssertionManager()) {
    self.assertionManager = assertionManager
  }

  func acquire() throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !held else { return }

    let result = assertionManager.createPreventUserIdleSystemSleep(
      name: "Codexetine: supported coding agent is running",
      assertionID: &assertionID
    )
    guard result == kIOReturnSuccess else {
      throw BackendError.assertionFailed(result)
    }
    held = true
  }

  func renew() throws {}

  func release() throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard held else { return }
    let result = assertionManager.release(assertionID)
    guard result == kIOReturnSuccess else {
      throw BackendError.assertionReleaseFailed(result)
    }
    assertionID = 0
    held = false
  }

  func releaseForExternalTermination() throws {
    // IOPMAssertionRelease is the narrow, non-privileged operation allowed on
    // the external termination path. Closed-lid recovery stays with its
    // lease/watchdog owner.
    try release()
  }
}
