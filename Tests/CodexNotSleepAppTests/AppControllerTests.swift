import AppKit
import CodexNotSleepCore
import Foundation
import Testing

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
    #expect(controller.phase == .protected(reason: "active_codex_task"))
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

    #expect(controller.phase == .protected(reason: "active_codex_task"))
    #expect(backend.acquireCount == 1)
    #expect(backend.releaseCount == 0)
  }

  @Test
  func graceDeadlineReleasesAtDeadlineWithoutReconciliation() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let backend = TestSleepProtectionBackend()
    let activity = TestCodexActivityProvider(snapshot: .active(turnCount: 1))
    let scheduler = TestGraceDeadlineScheduler()
    var currentTime = Date(timeIntervalSince1970: 20_000)
    let controller = makeController(
      defaults: defaults,
      backend: backend,
      activity: activity,
      graceSeconds: 15,
      graceDeadlineScheduler: scheduler,
      now: { currentTime }
    )

    controller.refreshCodexActivity()
    activity.snapshot = .idle
    controller.refreshCodexActivity()

    let deadline = try #require(scheduler.scheduledDeadline)
    #expect(deadline == currentTime.addingTimeInterval(15))
    currentTime = deadline.addingTimeInterval(-0.1)
    scheduler.fire()
    #expect(controller.phase != .idle)
    #expect(backend.releaseCount == 0)

    currentTime = deadline
    scheduler.fire()
    #expect(controller.phase == .idle)
    #expect(backend.releaseCount == 1)
  }

  @Test
  func graceDeadlineIsCancelledByNewWorkAndDisabling() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let scheduler = TestGraceDeadlineScheduler()
    let activity = TestCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = makeController(
      defaults: defaults,
      backend: TestSleepProtectionBackend(),
      activity: activity,
      graceSeconds: 15,
      graceDeadlineScheduler: scheduler
    )

    controller.refreshCodexActivity()
    activity.snapshot = .idle
    controller.refreshCodexActivity()
    #expect(scheduler.scheduledDeadline != nil)

    activity.snapshot = .active(turnCount: 1)
    controller.refreshCodexActivity()
    #expect(scheduler.cancelCount > 0)
    #expect(scheduler.scheduledDeadline == nil)

    activity.snapshot = .idle
    controller.refreshCodexActivity()
    controller.setProtectionEnabled(false)
    #expect(scheduler.scheduledDeadline == nil)
  }

  @Test
  func shutdownCancelsGraceDeadline() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let scheduler = TestGraceDeadlineScheduler()
    let activity = TestCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = makeController(
      defaults: defaults,
      backend: TestSleepProtectionBackend(),
      activity: activity,
      graceSeconds: 15,
      graceDeadlineScheduler: scheduler
    )

    controller.refreshCodexActivity()
    activity.snapshot = .idle
    controller.refreshCodexActivity()
    #expect(scheduler.scheduledDeadline != nil)

    controller.start()
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

    #expect(scheduler.scheduledDeadline == nil)
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

    #expect(controller.phase == .protected(reason: "active_codex_task"))
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

  @Test
  func optionalClosedLidFailureKeepsOrdinaryProtectionHeld() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let idle = TestControllerIOPMBackend()
    let closedLid = TestControllerClosedLidBackend(enabled: true)
    closedLid.failAcquire = true
    let backend = CombinedSleepProtectionBackend(idleSleep: idle, closedLid: closedLid)
    let controller = AppController(
      defaults: defaults,
      backend: backend,
      codexActivityProvider: TestCodexActivityProvider(snapshot: .active(turnCount: 1)),
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )

    controller.refreshCodexActivity()

    #expect(idle.isHeld)
    #expect(controller.menuIssue == .closedLidRecoveryRequired)
    #expect(controller.isProtectionEnabled)
  }

  @Test
  func setupRequiredClosedLidFailureOffersRepairAndRetriesOptionalAcquire() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)
    defaults.set(true, forKey: ProtectionPreferenceStore.closedLidKey)

    let idle = TestControllerIOPMBackend()
    let closedLid = TestControllerClosedLidBackend(
      enabled: true,
      setupState: .notInstalled
    )
    closedLid.failAcquireAsSetup = true
    let backend = CombinedSleepProtectionBackend(idleSleep: idle, closedLid: closedLid)
    let controller = AppController(
      defaults: defaults,
      backend: backend,
      codexActivityProvider: TestCodexActivityProvider(snapshot: .active(turnCount: 1)),
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )

    controller.refreshCodexActivity()
    #expect(idle.isHeld)
    #expect(controller.menuIssue == .closedLidSetupRepairRequired)

    closedLid.failAcquireAsSetup = false
    controller.resolveMenuIssue()

    #expect(closedLid.prepareCount == 1)
    #expect(closedLid.setupInspectionCount == 2)
    #expect(idle.isHeld)
    #expect(closedLid.isHeld)
    #expect(controller.menuIssue == nil)
  }

  @Test
  func setupRepairUsesTargetedClosedLidReleaseWithoutRepeatingIOPMRelease() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)
    defaults.set(true, forKey: ProtectionPreferenceStore.closedLidKey)

    let idle = TestControllerIOPMBackend()
    let closedLid = TestControllerClosedLidBackend(
      enabled: true,
      setupState: .notInstalled
    )
    let backend = CombinedSleepProtectionBackend(idleSleep: idle, closedLid: closedLid)
    let controller = AppController(
      defaults: defaults,
      backend: backend,
      codexActivityProvider: TestCodexActivityProvider(snapshot: .active(turnCount: 1)),
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )
    controller.refreshCodexActivity()
    closedLid.failReleaseAsSetup = true

    controller.setProtectionEnabled(false)

    #expect(controller.menuIssue == .closedLidSetupRepairRequired)
    #expect(idle.releaseCount == 1)

    closedLid.failReleaseAsSetup = false
    controller.resolveMenuIssue()

    #expect(idle.releaseCount == 1)
    #expect(!closedLid.isHeld)
    #expect(controller.menuIssue == nil)
  }

  @Test
  func disablingClosedLidKeepsOrdinaryIOPMProtection() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)
    defaults.set(true, forKey: ProtectionPreferenceStore.closedLidKey)

    let idle = TestControllerIOPMBackend()
    let closedLid = TestControllerClosedLidBackend(enabled: true)
    let backend = CombinedSleepProtectionBackend(idleSleep: idle, closedLid: closedLid)
    let controller = AppController(
      defaults: defaults,
      backend: backend,
      codexActivityProvider: TestCodexActivityProvider(snapshot: .active(turnCount: 1)),
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )

    controller.refreshCodexActivity()
    #expect(idle.isHeld)
    #expect(closedLid.isHeld)

    controller.toggleClosedLidProtection()

    #expect(!controller.isClosedLidEnabled)
    #expect(idle.isHeld)
    #expect(!closedLid.isHeld)
    #expect(controller.menuIssue == nil)
  }

  @Test
  func failedClosedLidSetupLeavesItemUncheckedAndIOPMUsable() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)
    defaults.set(false, forKey: ProtectionPreferenceStore.closedLidKey)

    let idle = TestControllerIOPMBackend()
    let closedLid = TestControllerClosedLidBackend(
      enabled: false,
      setupState: .notInstalled
    )
    closedLid.failPrepare = true
    let backend = CombinedSleepProtectionBackend(idleSleep: idle, closedLid: closedLid)
    let activity = TestCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = AppController(
      defaults: defaults,
      backend: backend,
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )

    controller.toggleClosedLidProtection()

    #expect(!controller.isClosedLidEnabled)
    #expect(controller.menuIssue == .permissionRequired)
    controller.refreshCodexActivity()
    #expect(idle.isHeld)
  }

  @Test
  func ordinaryRecoveryDoesNotPrepareOptionalClosedLidSetup() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let idle = TestControllerIOPMBackend()
    let closedLid = TestControllerClosedLidBackend(enabled: false)
    let backend = CombinedSleepProtectionBackend(idleSleep: idle, closedLid: closedLid)
    let controller = AppController(
      defaults: defaults,
      backend: backend,
      codexActivityProvider: TestCodexActivityProvider(snapshot: .active(turnCount: 1)),
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )
    controller.refreshCodexActivity()
    idle.failNextRelease = true
    controller.setProtectionEnabled(false)
    #expect(controller.menuIssue == .sleepRestoreRequired)

    controller.resolveMenuIssue()

    #expect(closedLid.prepareCount == 0)
    #expect(controller.menuIssue == nil)
  }

  @Test
  func failedQuitRearmsMonitoringAndBatteryCallbacks() async throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let backend = TestSleepProtectionBackend()
    let battery = TestBatteryStatusProvider(status: nil)
    let activity = TestCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = AppController(
      defaults: defaults,
      backend: backend,
      batteryStatusProvider: battery,
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )
    controller.start()
    controller.refreshCodexActivity()
    backend.failNextRelease = true

    controller.quit()

    #expect(controller.menuIssue == .sleepRestoreRequired)
    #expect(battery.startCount >= 2)
    #expect(battery.stopCount == 1)
    for _ in 0..<40 where activity.startMonitoringCount < 2 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(activity.startMonitoringCount >= 2)
    #expect(activity.stopMonitoringCount == 1)
  }

  @Test
  func quitReleasesSleepOnlyAfterBrightnessShutdownRestoreCompletes() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let backend = TestSleepProtectionBackend()
    let brightness = TestShutdownBrightnessController()
    let controller = AppController(
      defaults: defaults,
      backend: backend,
      codexActivityProvider: TestCodexActivityProvider(snapshot: .active(turnCount: 1)),
      protectionGraceSeconds: 0,
      startsAutomatically: false,
      lidBrightnessController: brightness
    )
    controller.start()
    controller.refreshCodexActivity()
    backend.failNextRelease = true

    controller.quit()
    #expect(backend.releaseCount == 0)

    brightness.finish(.restored)

    #expect(backend.releaseCount == 1)
    #expect(controller.menuIssue == .sleepRestoreRequired)
  }

  @Test
  func externalTerminationUsesSynchronousBrightnessAndBackendCleanup() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    let backend = TestSleepProtectionBackend()
    let brightness = TestShutdownBrightnessController()
    let controller = AppController(
      defaults: defaults,
      backend: backend,
      codexActivityProvider: TestCodexActivityProvider(snapshot: .active(turnCount: 1)),
      protectionGraceSeconds: 0,
      startsAutomatically: false,
      lidBrightnessController: brightness
    )

    controller.start()
    controller.refreshCodexActivity()
    #expect(backend.isHeld)

    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

    #expect(brightness.externalRestoreCount == 1)
    #expect(brightness.shutdownRestoreCount == 0)
    #expect(backend.releaseCount == 1)
    #expect(!backend.isHeld)
  }

  @Test
  func closedLidPreferenceMigratesOnlyWhenTheNewKeyIsAbsent() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    defaults.set(true, forKey: ProtectionPreferenceStore.key)
    let backend = TestControllerClosedLidBackend(
      enabled: false,
      setupState: .installedAndValid
    )

    let controller = AppController(
      defaults: defaults,
      backend: backend,
      codexActivityProvider: TestCodexActivityProvider(snapshot: .idle),
      startsAutomatically: false
    )
    controller.start()

    #expect(defaults.bool(forKey: ProtectionPreferenceStore.closedLidKey))
    #expect(controller.isClosedLidEnabled)
    #expect(backend.setupInspectionCount == 1)

    let explicitDefaults = try makeDefaults()
    defer { explicitDefaults.removePersistentDomain(forName: defaultsSuiteName(explicitDefaults)) }
    explicitDefaults.set(false, forKey: ProtectionPreferenceStore.closedLidKey)
    let explicitBackend = TestControllerClosedLidBackend(
      enabled: false,
      setupState: .installedAndValid
    )
    let explicitController = AppController(
      defaults: explicitDefaults,
      backend: explicitBackend,
      codexActivityProvider: TestCodexActivityProvider(snapshot: .idle),
      startsAutomatically: false
    )
    explicitController.start()

    #expect(!explicitDefaults.bool(forKey: ProtectionPreferenceStore.closedLidKey))
    #expect(explicitBackend.setupInspectionCount == 0)
  }

  @Test
  func closedLidMenuTitleIsStableAndCheckableByState() throws {
    let defaults = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let backend = TestControllerClosedLidBackend(enabled: false)
    let controller = AppController(
      defaults: defaults,
      backend: backend,
      codexActivityProvider: TestCodexActivityProvider(snapshot: .idle),
      startsAutomatically: false
    )

    #expect(controller.closedLidMenuTitle == "Keep Awake with Lid Closed")
    #expect(!controller.isClosedLidEnabled)
  }

  private func makeController(
    defaults: UserDefaults,
    backend: any SleepProtectionBackend,
    battery: TestBatteryStatusProvider = TestBatteryStatusProvider(status: nil),
    activity: TestCodexActivityProvider,
    graceSeconds: TimeInterval,
    graceDeadlineScheduler: any GraceDeadlineScheduling = TestGraceDeadlineScheduler(),
    now: @escaping () -> Date = Date.init
  ) -> AppController {
    AppController(
      defaults: defaults,
      backend: backend,
      batteryStatusProvider: battery,
      codexActivityProvider: activity,
      protectionGraceSeconds: graceSeconds,
      startsAutomatically: false,
      graceDeadlineScheduler: graceDeadlineScheduler,
      now: now
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

private final class TestControllerIOPMBackend: SleepProtectionBackend {
  let identifier = "controller-iopm-test"
  private(set) var isHeld = false
  var failNextRelease = false
  private(set) var releaseCount = 0

  func acquire() throws { isHeld = true }
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

private final class TestControllerClosedLidBackend:
  SleepProtectionBackend,
  ClosedLidProtectionManaging,
  ClosedLidProtectionInspecting,
  ClosedLidProtectionReleasing
{
  let identifier = "controller-closed-lid-test"
  private(set) var isHeld = false
  private(set) var isClosedLidEnabled: Bool
  private(set) var prepareCount = 0
  private(set) var setupInspectionCount = 0
  var setupState: PowerProtectSetupState
  var failAcquire = false
  var failAcquireAsSetup = false
  var failReleaseAsSetup = false
  var failPrepare = false

  init(enabled: Bool, setupState: PowerProtectSetupState = .installedAndValid) {
    isClosedLidEnabled = enabled
    self.setupState = setupState
  }

  var requiresSetup: Bool { false }

  func prepare() throws { try prepareClosedLid() }

  func prepareClosedLid() throws {
    prepareCount += 1
    if failPrepare { throw TestBackendError.setup }
    setupState = .installedAndValid
  }

  func setClosedLidEnabled(_ enabled: Bool) {
    isClosedLidEnabled = enabled
  }

  var closedLidSetupState: PowerProtectSetupState {
    setupInspectionCount += 1
    return setupState
  }

  func recover() throws {}

  func acquire() throws {
    if failAcquireAsSetup { throw PowerProtectError.setupRequired }
    if failAcquire { throw TestBackendError.setup }
    isHeld = true
  }

  func renew() throws {}
  func release() throws {
    if failReleaseAsSetup { throw PowerProtectError.setupRequired }
    isHeld = false
  }
  func releaseClosedLid() throws { try release() }
}

private enum TestBackendError: Error {
  case setup
  case recovery
  case release
}

private final class TestBatteryStatusProvider: BatteryStatusProviding, @unchecked Sendable {
  var status: BatteryStatus?
  private(set) var startCount = 0
  private(set) var stopCount = 0

  init(status: BatteryStatus?) {
    self.status = status
  }

  func currentStatus() -> BatteryStatus? {
    status
  }

  func startMonitoring(onChange: @escaping @Sendable () -> Void) {
    startCount += 1
  }

  func stopMonitoring() {
    stopCount += 1
  }
}

@MainActor
private final class TestShutdownBrightnessController: LidBrightnessControlling {
  private var completion: (@MainActor @Sendable (BrightnessRestoreResult) -> Void)?
  private(set) var shutdownRestoreCount = 0
  private(set) var externalRestoreCount = 0

  func setCodexWorking(_ isWorking: Bool) {}
  func reset() {}

  func restoreForExternalTermination() -> BrightnessRestoreResult {
    externalRestoreCount += 1
    return .restored
  }

  func restoreForShutdown(
    completion: @escaping @MainActor @Sendable (BrightnessRestoreResult) -> Void
  ) {
    shutdownRestoreCount += 1
    self.completion = completion
  }

  func finish(_ result: BrightnessRestoreResult) {
    completion?(result)
    completion = nil
  }
}

@MainActor
private final class TestGraceDeadlineScheduler: GraceDeadlineScheduling {
  private(set) var scheduledDeadline: Date?
  private var scheduledHandler: (@MainActor @Sendable () -> Void)?
  private(set) var scheduleCount = 0
  private(set) var cancelCount = 0

  func schedule(
    at deadline: Date,
    handler: @escaping @MainActor @Sendable () -> Void
  ) {
    scheduledDeadline = deadline
    scheduledHandler = handler
    scheduleCount += 1
  }

  func cancel() {
    scheduledDeadline = nil
    scheduledHandler = nil
    cancelCount += 1
  }

  func fire() {
    scheduledHandler?()
  }
}

private final class TestCodexActivityProvider: CodexActivityProviding {
  var snapshot: CodexActivitySnapshot
  private(set) var refreshCount = 0
  private(set) var startMonitoringCount = 0
  private(set) var stopMonitoringCount = 0

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

  func stopMonitoring() {
    stopMonitoringCount += 1
  }
}
