import Foundation
import Testing
import CodexNotSleepCore

@testable import CodexNotSleepApp

@Suite
@MainActor
struct AppControllerTests {
  @Test
  func activeCodexWorkAcquiresAndDisablingReleasesProtection() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(false, forKey: ProtectionPreferenceStore.key)

    let backend = TestSleepProtectionBackend()
    let activity = TestCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = makeController(
      defaults: defaults,
      backend: backend,
      activity: activity,
      graceSeconds: 0
    )

    controller.setProtectionEnabled(true)
    controller.refreshCodexActivity()

    #expect(controller.isProtectionEnabled)
    #expect(controller.phase == .protected(reason: "running_agent"))
    #expect(backend.acquireCount == 1)
    #expect(backend.isHeld)

    controller.setProtectionEnabled(false)

    #expect(!controller.isProtectionEnabled)
    #expect(controller.phase == .idle)
    #expect(backend.releaseCount == 1)
    #expect(!backend.isHeld)
  }

  @Test
  func aReplacementTaskKeepsProtectionDuringGrace() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let backend = TestSleepProtectionBackend()
    let activity = TestCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = makeController(
      defaults: defaults,
      backend: backend,
      activity: activity,
      graceSeconds: 3
    )

    controller.refreshCodexActivity()
    activity.snapshot = .idle
    controller.refreshCodexActivity()
    #expect(controller.phase != .idle)
    #expect(backend.isHeld)
    #expect(backend.releaseCount == 0)

    activity.snapshot = .active(turnCount: 1)
    controller.refreshCodexActivity()

    #expect(controller.phase == .protected(reason: "running_agent"))
    #expect(backend.acquireCount == 1)
    #expect(backend.releaseCount == 0)
  }

  @Test
  func lowBatteryAtThresholdReleasesOnlyOnBattery() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let backend = TestSleepProtectionBackend()
    let battery = TestBatteryStatusProvider(
      status: BatteryStatus(chargePercent: 50, isRunningOnBattery: true)
    )
    let activity = TestCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = makeController(
      defaults: defaults,
      backend: backend,
      battery: battery,
      activity: activity,
      graceSeconds: 0
    )

    controller.refreshCodexActivity()
    #expect(backend.isHeld)

    battery.status = BatteryStatus(chargePercent: 10, isRunningOnBattery: true)
    controller.refreshCodexActivity()
    #expect(!backend.isHeld)

    battery.status = BatteryStatus(chargePercent: 9, isRunningOnBattery: false)
    controller.refreshCodexActivity()
    #expect(backend.isHeld)
  }

  @Test
  func unavailableActivityProtectsConservativelyWhileEnabled() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let backend = TestSleepProtectionBackend()
    let activity = TestCodexActivityProvider(
      snapshot: .unavailable(protectConservatively: true)
    )
    let controller = makeController(
      defaults: defaults,
      backend: backend,
      activity: activity,
      graceSeconds: 0
    )

    controller.refreshCodexActivity()

    #expect(controller.phase == .protected(reason: "running_agent"))
    #expect(backend.isHeld)
    #expect(controller.visibleError == nil)
  }

  @Test
  func disabledProtectionDoesNotStartActivityRefreshes() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(false, forKey: ProtectionPreferenceStore.key)

    let activity = TestCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = makeController(
      defaults: defaults,
      backend: TestSleepProtectionBackend(),
      activity: activity,
      graceSeconds: 0
    )

    controller.start()

    #expect(activity.refreshCount == 0)
    #expect(activity.startMonitoringCount == 0)
  }

  @Test
  func setupRunsBeforeFirstEnableAndFailureRemainsActionable() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(false, forKey: ProtectionPreferenceStore.key)

    let backend = TestSleepProtectionBackend(requiresSetup: true)
    let controller = makeController(
      defaults: defaults,
      backend: backend,
      activity: TestCodexActivityProvider(snapshot: .idle),
      graceSeconds: 0
    )

    controller.setProtectionEnabled(true)

    #expect(controller.isProtectionEnabled)
    #expect(!backend.requiresSetup)
    #expect(backend.prepareCount == 1)
    #expect(backend.recoverCount == 1)
    #expect(controller.menuIssue == nil)

    let failingDefaults = try makeDefaults()
    defer { failingDefaults.removePersistentDomain(forName: defaultsSuiteName(failingDefaults)) }
    failingDefaults.set(false, forKey: ProtectionPreferenceStore.key)
    let failingBackend = TestSleepProtectionBackend(
      requiresSetup: true,
      prepareError: TestBackendError.setup
    )
    let failingController = makeController(
      defaults: failingDefaults,
      backend: failingBackend,
      activity: TestCodexActivityProvider(snapshot: .idle),
      graceSeconds: 0
    )

    failingController.setProtectionEnabled(true)

    #expect(!failingController.isProtectionEnabled)
    #expect(failingController.menuIssue == .permissionRequired)
  }

  @Test
  func releaseFailureCanBeResolvedFromTheMenu() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let backend = TestSleepProtectionBackend()
    let activity = TestCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = makeController(
      defaults: defaults,
      backend: backend,
      activity: activity,
      graceSeconds: 0
    )
    controller.refreshCodexActivity()
    backend.failNextRelease = true

    controller.setProtectionEnabled(false)

    #expect(backend.isHeld)
    #expect(controller.menuIssue == .sleepRestoreRequired)

    controller.resolveMenuIssue()

    #expect(!backend.isHeld)
    #expect(controller.menuIssue == nil)
  }

  @Test
  func failedRecoveryBlocksActivationUntilSleepIsRestored() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let backend = TestSleepProtectionBackend()
    backend.failRecovery = true
    let controller = makeController(
      defaults: defaults,
      backend: backend,
      activity: TestCodexActivityProvider(snapshot: .active(turnCount: 1)),
      graceSeconds: 0
    )
    controller.start()

    #expect(controller.menuIssue == .sleepRestoreRequired)
    #expect(backend.acquireCount == 0)

    backend.failRecovery = false
    controller.resolveMenuIssue()

    #expect(controller.menuIssue == nil)
    #expect(backend.releaseCount == 1)
  }

  private func makeController(
    defaults: UserDefaults,
    backend: TestSleepProtectionBackend,
    battery: TestBatteryStatusProvider = TestBatteryStatusProvider(status: nil),
    activity: TestCodexActivityProvider,
    graceSeconds: TimeInterval
  ) -> AppController {
    AppController(
      defaults: defaults,
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome()),
      backend: backend,
      batteryStatusProvider: battery,
      codexActivityProvider: activity,
      protectionGraceSeconds: graceSeconds,
      startsAutomatically: false
    )
  }

  private func fixtureHome() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "CodexNotSleep.AppControllerTests.\(UUID().uuidString)")
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "CodexNotSleep.AppControllerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(suiteName, forKey: Self.suiteNameKey)
    return defaults
  }

  private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: Self.suiteNameKey)!
  }

  private static let suiteNameKey = "CodexNotSleep.AppControllerTests.suiteName"
}

private final class TestSleepProtectionBackend: SleepProtectionBackend {
  let identifier = "app-controller-test"
  private(set) var isHeld = false
  var requiresSetup: Bool
  let prepareError: Error?
  var failNextRelease = false
  var failRecovery = false
  private(set) var prepareCount = 0
  private(set) var recoverCount = 0
  private(set) var acquireCount = 0
  private(set) var releaseCount = 0

  init(requiresSetup: Bool = false, prepareError: Error? = nil) {
    self.requiresSetup = requiresSetup
    self.prepareError = prepareError
  }

  func prepare() throws {
    prepareCount += 1
    if let prepareError { throw prepareError }
    requiresSetup = false
  }

  func recover() throws {
    recoverCount += 1
    if failRecovery { throw TestBackendError.recovery }
  }

  func acquire() throws {
    acquireCount += 1
    isHeld = true
  }

  func renew() throws {}

  func release() throws {
    releaseCount += 1
    if failNextRelease {
      failNextRelease = false
      throw TestBackendError.release
    }
    isHeld = false
  }
}

private enum TestBackendError: Error {
  case setup
  case recovery
  case release
}

private final class TestBatteryStatusProvider: BatteryStatusProviding, @unchecked Sendable {
  var status: BatteryStatus?

  init(status: BatteryStatus?) {
    self.status = status
  }

  func currentStatus() -> BatteryStatus? {
    status
  }
}

private final class TestCodexActivityProvider: CodexActivityProviding {
  var snapshot: CodexActivitySnapshot
  private(set) var refreshCount = 0
  private(set) var startMonitoringCount = 0

  init(snapshot: CodexActivitySnapshot) {
    self.snapshot = snapshot
  }

  func refresh() -> CodexActivitySnapshot {
    refreshCount += 1
    return snapshot
  }

  func startMonitoring(onChange: @escaping @Sendable () -> Void) {
    startMonitoringCount += 1
  }
}
