import Foundation
import MethamphetamineCore
import Testing

@testable import MethamphetamineApp

@Suite
@MainActor
struct PowerProtectTests {
  @Test
  func ownedSleepSettingIsEnabledAndRestored() throws {
    let fixture = try Fixture(
      results: [
        Self.pmsetState(false), Self.commandSucceeded(), Self.pmsetState(true),
        Self.pmsetState(true), Self.commandSucceeded(), Self.pmsetState(false),
      ]
    )
    defer { fixture.cleanup() }

    try fixture.backend.acquire()

    #expect(fixture.backend.isHeld)
    #expect(fixture.leaseStore.hasLease)
    #expect(fixture.watchdog.startCount == 1)

    try fixture.backend.release()

    #expect(!fixture.backend.isHeld)
    #expect(!fixture.leaseStore.hasLease)
    #expect(fixture.watchdog.stopCount == 1)
    #expect(
      fixture.runner.invocations.map { $0.arguments } == [
        ["-g"],
        ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"],
        ["-g"],
        ["-g"],
        ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"],
        ["-g"],
      ])
  }

  @Test
  func preexistingDisabledSleepIsNeverReset() throws {
    let fixture = try Fixture(results: [Self.pmsetState(true)])
    defer { fixture.cleanup() }

    try fixture.backend.acquire()
    try fixture.backend.release()

    #expect(!fixture.backend.isHeld)
    #expect(!fixture.leaseStore.hasLease)
    #expect(fixture.runner.invocations.count == 1)
    #expect(fixture.runner.invocations.first?.executable == "/usr/bin/pmset")
  }

  @Test
  func renewRestoresOwnedProtectionIfAnotherProcessResetsIt() throws {
    let fixture = try Fixture(
      results: [
        Self.pmsetState(false), Self.commandSucceeded(), Self.pmsetState(true),
        Self.pmsetState(false), Self.commandSucceeded(), Self.pmsetState(true),
        Self.pmsetState(true), Self.commandSucceeded(), Self.pmsetState(false),
      ]
    )
    defer { fixture.cleanup() }

    try fixture.backend.acquire()
    try fixture.backend.renew()
    try fixture.backend.release()

    let enableCommands = fixture.runner.invocations.filter {
      $0.arguments == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]
    }
    #expect(enableCommands.count == 2)
    #expect(fixture.watchdog.startCount == 1)
  }

  @Test
  func renewTakesOwnershipIfInheritedProtectionEnds() throws {
    let fixture = try Fixture(
      results: [
        Self.pmsetState(true), Self.pmsetState(false),
        Self.commandSucceeded(), Self.pmsetState(true),
        Self.pmsetState(true), Self.commandSucceeded(), Self.pmsetState(false),
      ]
    )
    defer { fixture.cleanup() }

    try fixture.backend.acquire()
    try fixture.backend.renew()

    #expect(fixture.leaseStore.hasLease)
    #expect(fixture.watchdog.startCount == 1)

    try fixture.backend.release()

    #expect(!fixture.leaseStore.hasLease)
    #expect(fixture.watchdog.stopCount == 1)
  }

  @Test
  func failedRestoreKeepsLeaseAndRetries() throws {
    let fixture = try Fixture(
      results: [
        Self.pmsetState(false), Self.commandSucceeded(), Self.pmsetState(true),
        Self.pmsetState(true), Self.commandFailed(),
        Self.pmsetState(true), Self.commandSucceeded(), Self.pmsetState(false),
      ]
    )
    defer { fixture.cleanup() }
    try fixture.backend.acquire()

    do {
      try fixture.backend.release()
      Issue.record("Expected restore to fail")
    } catch let error as PowerProtectError {
      #expect(error == .restoreFailed)
    }

    #expect(fixture.backend.isHeld)
    #expect(fixture.leaseStore.hasLease)
    #expect(fixture.watchdog.stopCount == 0)

    try fixture.backend.release()

    #expect(!fixture.backend.isHeld)
    #expect(!fixture.leaseStore.hasLease)
    #expect(fixture.watchdog.stopCount == 1)
  }

  @Test
  func staleLeaseIsRecoveredBeforeNewProtection() throws {
    let fixture = try Fixture(results: [Self.pmsetState(false)])
    defer { fixture.cleanup() }
    _ = try fixture.leaseStore.begin()
    let backend = PMSetPowerProtectBackend(
      installer: FakePowerProtectInstaller(isInstalled: true),
      runner: fixture.runner,
      leaseStore: fixture.leaseStore,
      watchdog: fixture.watchdog
    )

    #expect(backend.isHeld)

    try backend.recover()

    #expect(!backend.isHeld)
    #expect(!fixture.leaseStore.hasLease)
    #expect(fixture.runner.invocations.map(\.arguments) == [["-g"]])
  }

  @Test
  func alreadyEnabledSleepClearsLeaseWithoutInstalledPermission() throws {
    let fixture = try Fixture(
      results: [
        PowerProtectCommandResult(
          status: 0,
          output: "System-wide power settings:\n"
        )
      ]
    )
    defer { fixture.cleanup() }
    _ = try fixture.leaseStore.begin()
    let backend = PMSetPowerProtectBackend(
      installer: FakePowerProtectInstaller(isInstalled: false),
      runner: fixture.runner,
      leaseStore: fixture.leaseStore,
      watchdog: fixture.watchdog
    )

    try backend.recover()

    #expect(!backend.isHeld)
    #expect(!fixture.leaseStore.hasLease)
    #expect(fixture.runner.invocations.map(\.arguments) == [["-g"]])
  }

  @Test
  func installerUsesNarrowUIDSpecificRuleAndReportsCancellation() async throws {
    let runner = RecordingPowerProtectRunner(results: [])
    let authorizationRunner = RecordingPowerProtectAuthorizationRunner(
      result: PowerProtectCommandResult(status: -128, output: "User canceled")
    )
    let installer = PowerProtectInstaller(
      runner: runner,
      authorizationRunner: authorizationRunner,
      userID: 501,
      installationCheck: { false }
    )

    do {
      try await installer.install()
      Issue.record("Expected setup cancellation")
    } catch let error as PowerProtectError {
      #expect(error == .setupCancelled)
    }

    #expect(runner.invocations.isEmpty)
    let appleScript = try #require(authorizationRunner.scripts.first)
    #expect(
      appleScript.contains(
        "with prompt \"Allow Methamphetamine to keep your Mac running with the lid closed. You'll only need to confirm once.\""
      ))
    var compilationError: NSDictionary?
    let compiled = NSAppleScript(source: appleScript)?.compileAndReturnError(&compilationError)
    #expect(compiled == true)
    #expect(compilationError == nil)
    let encoded = try #require(appleScript.split(separator: "'").dropFirst().first)
    let scriptData = try #require(Data(base64Encoded: String(encoded)))
    let shellScript = String(decoding: scriptData, as: UTF8.self)

    #expect(
      shellScript.contains(
        "#501 ALL=(root) NOPASSWD:NOSETENV: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
      ))
    #expect(shellScript.contains("/usr/sbin/visudo -cf"))
    #expect(shellScript.contains("/usr/bin/mktemp"))
    #expect(!shellScript.contains("%admin"))
    #expect(!shellScript.contains("ALL=(ALL)"))
    let syntaxCheck = try ProcessPowerProtectCommandRunner().run(
      executable: "/bin/sh",
      arguments: ["-n", "-c", shellScript]
    )
    #expect(syntaxCheck.status == 0)
  }

  @Test
  func authorizationEnvironmentRemovesShellStartupHooks() {
    let sanitized = PowerProtectAuthorizationEnvironment.sanitized([
      "HOME": "/Users/test",
      "PATH": "/untrusted",
      "BASH_ENV": "/tmp/injected",
      "SHELLOPTS": "xtrace",
      "PS4": "$(touch /tmp/injected)",
      "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
      "BASH_FUNC_bad%%": "() { true; }",
    ])

    #expect(sanitized["HOME"] == "/Users/test")
    #expect(sanitized["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(sanitized["LANG"] == "C")
    #expect(sanitized["LC_ALL"] == "C")
    #expect(sanitized["BASH_ENV"] == nil)
    #expect(sanitized["SHELLOPTS"] == nil)
    #expect(sanitized["PS4"] == nil)
    #expect(sanitized["DYLD_INSERT_LIBRARIES"] == nil)
    #expect(sanitized["BASH_FUNC_bad%%"] == nil)
  }

  @Test
  func authorizationPreviewUsesTheRealPromptWithoutChangingSettings() {
    let source = PowerProtectInstaller.authorizationPreviewAppleScript
    #expect(source.contains("do shell script \"/usr/bin/true\""))
    #expect(source.contains("with prompt \"\(PowerProtectInstaller.authorizationPrompt)\""))
    #expect(!source.contains("pmset"))
    #expect(!source.contains("sudoers"))

    var compilationError: NSDictionary?
    let compiled = NSAppleScript(source: source)?.compileAndReturnError(&compilationError)
    #expect(compiled == true)
    #expect(compilationError == nil)
  }

  @Test
  func existingInstallerRequiresPermissionForEnableAndDisable() {
    let runner = RecordingPowerProtectRunner(
      results: [Self.commandSucceeded(), Self.commandFailed()]
    )
    let installer = PowerProtectInstaller(
      runner: runner,
      userID: 501,
      installationCheck: { true }
    )

    #expect(!installer.isInstalled)
    #expect(
      runner.invocations.map(\.arguments) == [
        ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"],
        ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"],
      ])
  }

  @Test
  func installerRevalidatesPermissionAfterItsFileDisappears() {
    let runner = RecordingPowerProtectRunner(
      results: [Self.commandSucceeded(), Self.commandSucceeded()]
    )
    var fileExists = true
    let installer = PowerProtectInstaller(
      runner: runner,
      userID: 501,
      installationCheck: { fileExists }
    )

    #expect(installer.isInstalled)
    fileExists = false
    #expect(!installer.isInstalled)
    #expect(runner.invocations.count == 2)
  }

  @Test
  func combinedBackendRepairsAComponentMissingDuringRenewal() throws {
    let idle = PartialSleepProtectionBackend(isHeld: false)
    let closedLid = PartialSleepProtectionBackend(isHeld: true)
    let backend = CombinedSleepProtectionBackend(idleSleep: idle, closedLid: closedLid)

    try backend.renew()

    #expect(idle.acquireCount == 1)
    #expect(closedLid.renewCount == 1)
    #expect(backend.isHeld)
  }

  @Test
  func watchdogShellScriptHasValidSyntaxAndRetriesCleanup() throws {
    let runner = ProcessPowerProtectCommandRunner()
    let result = try runner.run(
      executable: "/bin/sh",
      arguments: ["-n", "-c", ProcessPowerProtectWatchdog.watchdogScript]
    )

    #expect(result.status == 0)
    #expect(ProcessPowerProtectWatchdog.watchdogScript.contains("while ["))
    #expect(ProcessPowerProtectWatchdog.watchdogScript.contains("/bin/sleep 2"))
  }

  private static func pmsetState(_ isDisabled: Bool) -> PowerProtectCommandResult {
    PowerProtectCommandResult(
      status: 0,
      output: "System-wide power settings:\n SleepDisabled\t\t\(isDisabled ? 1 : 0)\n"
    )
  }

  private static func commandSucceeded() -> PowerProtectCommandResult {
    PowerProtectCommandResult(status: 0, output: "")
  }

  private static func commandFailed() -> PowerProtectCommandResult {
    PowerProtectCommandResult(status: 1, output: "not permitted")
  }
}

@MainActor
private struct Fixture {
  let root: URL
  let runner: RecordingPowerProtectRunner
  let leaseStore: PowerProtectLeaseStore
  let watchdog: FakePowerProtectWatchdog
  let backend: PMSetPowerProtectBackend

  init(results: [PowerProtectCommandResult]) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "Methamphetamine.PowerProtectTests.\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    runner = RecordingPowerProtectRunner(results: results)
    leaseStore = PowerProtectLeaseStore(url: root.appending(path: "power-protect.lease"))
    watchdog = FakePowerProtectWatchdog()
    backend = PMSetPowerProtectBackend(
      installer: FakePowerProtectInstaller(isInstalled: true),
      runner: runner,
      leaseStore: leaseStore,
      watchdog: watchdog
    )
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct PowerProtectInvocation: Equatable, Sendable {
  let executable: String
  let arguments: [String]
  let environment: [String: String]?
}

private final class RecordingPowerProtectRunner: PowerProtectCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var results: [PowerProtectCommandResult]
  private var recordedInvocations: [PowerProtectInvocation] = []

  init(results: [PowerProtectCommandResult]) {
    self.results = results
  }

  var invocations: [PowerProtectInvocation] {
    lock.withLock { recordedInvocations }
  }

  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?
  ) throws -> PowerProtectCommandResult {
    try lock.withLock {
      recordedInvocations.append(
        PowerProtectInvocation(
          executable: executable,
          arguments: arguments,
          environment: environment
        )
      )
      guard !results.isEmpty else { throw RecordingRunnerError.missingResult }
      return results.removeFirst()
    }
  }
}

private enum RecordingRunnerError: Error {
  case missingResult
}

@MainActor
private final class RecordingPowerProtectAuthorizationRunner:
  PowerProtectAuthorizationRunning
{
  private(set) var scripts: [String] = []
  private let result: PowerProtectCommandResult

  init(result: PowerProtectCommandResult) {
    self.result = result
  }

  func run(script source: String) -> PowerProtectCommandResult {
    scripts.append(source)
    return result
  }
}

@MainActor
private final class PartialSleepProtectionBackend: SleepProtectionBackend {
  let identifier = "partial-fake"
  private(set) var isHeld: Bool
  private(set) var acquireCount = 0
  private(set) var renewCount = 0

  init(isHeld: Bool) {
    self.isHeld = isHeld
  }

  func acquire() throws {
    acquireCount += 1
    isHeld = true
  }

  func renew() throws {
    renewCount += 1
  }

  func release() {
    isHeld = false
  }
}

@MainActor
private final class FakePowerProtectInstaller: PowerProtectInstalling {
  var isInstalled: Bool

  init(isInstalled: Bool) {
    self.isInstalled = isInstalled
  }

  func install() async throws {
    isInstalled = true
  }
}

@MainActor
private final class FakePowerProtectWatchdog: PowerProtectWatchdogControlling {
  private(set) var startCount = 0
  private(set) var stopCount = 0

  func start(parentPID: Int32, leaseURL: URL, token: String) throws {
    startCount += 1
  }

  func stop() {
    stopCount += 1
  }
}
