import CodexNotSleepCore
import Foundation
import Testing

@testable import CodexNotSleepApp

@Suite
@MainActor
struct LaunchAtLoginControllerTests {
  @Test
  func registersInstalledAppOnceByDefault() {
    let service = FakeLaunchAtLoginService(status: .notRegistered)
    let controller = LaunchAtLoginController(
      service: service,
      canRegisterCurrentApp: { true }
    )

    #expect(controller.enableByDefault() == nil)
    #expect(service.registerCount == 1)
    #expect(service.status == .enabled)

    #expect(controller.enableByDefault() == nil)
    #expect(service.registerCount == 1)
  }

  @Test
  func doesNotRegisterFromReadOnlyOrUnbundledCopy() {
    let service = FakeLaunchAtLoginService(status: .notRegistered)
    let controller = LaunchAtLoginController(
      service: service,
      canRegisterCurrentApp: { false }
    )

    #expect(controller.enableByDefault() == nil)
    #expect(service.registerCount == 0)
  }

  @Test
  func unbundledDevelopmentRunDoesNotReportNotFoundAsAnError() {
    let service = FakeLaunchAtLoginService(status: .notFound)
    let controller = LaunchAtLoginController(
      service: service,
      canRegisterCurrentApp: { false }
    )

    #expect(controller.enableByDefault() == nil)
    #expect(service.registerCount == 0)
  }

  @Test
  func installedAppAttemptsRegistrationWhenNoSystemRecordExistsYet() {
    let service = FakeLaunchAtLoginService(status: .notFound)
    let controller = LaunchAtLoginController(
      service: service,
      canRegisterCurrentApp: { true }
    )

    #expect(controller.enableByDefault() == nil)
    #expect(service.registerCount == 1)
    #expect(service.status == .enabled)
  }

  @Test
  func respectsUserRevokingLoginItemInSystemSettings() {
    let service = FakeLaunchAtLoginService(status: .requiresApproval)
    let controller = LaunchAtLoginController(
      service: service,
      canRegisterCurrentApp: { true }
    )

    #expect(controller.enableByDefault() == nil)
    #expect(service.registerCount == 0)
  }

  @Test
  func pathEligibilityOnlyAllowsApplicationsDirectories() {
    let home = URL(filePath: "/Users/tester")
    #expect(
      LaunchAtLoginController.isEligibleAppPath(
        URL(filePath: "/Applications/Codex Not Sleep.app"),
        homeDirectory: home
      ))
    #expect(
      LaunchAtLoginController.isEligibleAppPath(
        URL(filePath: "/Users/tester/Applications/Codex Not Sleep.app"),
        homeDirectory: home
      ))
    #expect(
      !LaunchAtLoginController.isEligibleAppPath(
        URL(filePath: "/Users/tester/Documents/cns/dist/Codex Not Sleep.app"),
        homeDirectory: home
      ))
    #expect(
      !LaunchAtLoginController.isEligibleAppPath(
        URL(filePath: "/Users/tester/Downloads/Codex Not Sleep.app"),
        homeDirectory: home
      ))
    #expect(
      !LaunchAtLoginController.isEligibleAppPath(
        URL(filePath: "/Volumes/Codex Not Sleep/Codex Not Sleep.app"),
        homeDirectory: home
      ))
  }

  @Test
  func reportsRegistrationFailure() {
    let service = FakeLaunchAtLoginService(
      status: .notRegistered,
      registrationError: LaunchAtLoginTestError.failed
    )
    let controller = LaunchAtLoginController(
      service: service,
      canRegisterCurrentApp: { true }
    )

    #expect(controller.enableByDefault() == LaunchAtLoginController.failureMessage)
    #expect(service.registerCount == 1)
  }

  @Test
  func registrationRaceRespectsApprovalRevokedInSystemSettings() {
    let service = FakeLaunchAtLoginService(
      status: .notRegistered,
      registrationError: LaunchAtLoginTestError.failed,
      statusAfterRegistrationError: .requiresApproval
    )
    let controller = LaunchAtLoginController(
      service: service,
      canRegisterCurrentApp: { true }
    )

    #expect(controller.enableByDefault() == nil)
    #expect(service.registerCount == 1)
  }

  @Test
  func appStartEnablesLaunchAtLoginOnce() throws {
    let suiteName = "CodexNotSleep.LaunchAtLoginTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let launchAtLogin = RecordingLaunchAtLoginController()
    let controller = AppController(
      defaults: defaults,
      backend: LaunchAtLoginTestSleepProtectionBackend(),
      launchAtLoginController: launchAtLogin,
      startsAutomatically: false
    )

    controller.start()
    controller.start()

    #expect(launchAtLogin.enableCount == 1)
  }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
  var status: LaunchAtLoginStatus
  private let registrationError: Error?
  private let statusAfterRegistrationError: LaunchAtLoginStatus?
  private(set) var registerCount = 0

  init(
    status: LaunchAtLoginStatus,
    registrationError: Error? = nil,
    statusAfterRegistrationError: LaunchAtLoginStatus? = nil
  ) {
    self.status = status
    self.registrationError = registrationError
    self.statusAfterRegistrationError = statusAfterRegistrationError
  }

  func register() throws {
    registerCount += 1
    if let registrationError {
      if let statusAfterRegistrationError { status = statusAfterRegistrationError }
      throw registrationError
    }
    status = .enabled
  }
}

@MainActor
private final class RecordingLaunchAtLoginController: LaunchAtLoginControlling {
  private(set) var enableCount = 0

  func enableByDefault() -> String? {
    enableCount += 1
    return nil
  }
}

private final class LaunchAtLoginTestSleepProtectionBackend: SleepProtectionBackend {
  let identifier = "launch-at-login-test"
  var isHeld = false

  func acquire() throws {
    isHeld = true
  }

  func renew() throws {}

  func release() {
    isHeld = false
  }
}

private enum LaunchAtLoginTestError: Error {
  case failed
}
