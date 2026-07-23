import Foundation
import MethamphetamineCore
import Testing

@testable import MethamphetamineApp

@Suite
@MainActor
struct AppControllerProtectionTests {
  @Test
  func globalTogglePersistsAndControlsActiveCodexTask() throws {
    let suiteName = "Methamphetamine.AppControllerProtectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "agentSleepProtectionEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.AppControllerProtectionTests.\(UUID().uuidString)")
    let backend = FakeSleepProtectionBackend()
    let activity = FakeCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: backend,
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )
    let definition = CodingAgentDefinition(
      id: "test-agent",
      displayName: "Test Agent",
      executableNames: ["test-agent"],
      sortOrder: 0
    )
    controller.detectedAgents = [
      DetectedCodingAgent(definition: definition, isInstalled: true, isRunning: true)
    ]

    #expect(controller.menuIcon == "pill.fill")
    #expect(!backend.isHeld)

    controller.setProtectionEnabled(true)

    #expect(defaults.bool(forKey: "agentSleepProtectionEnabled"))
    #expect(backend.acquireCount == 1)
    #expect(controller.phase == .protected(reason: "running_agent"))

    controller.setProtectionEnabled(false)

    #expect(!defaults.bool(forKey: "agentSleepProtectionEnabled"))
    #expect(!backend.isHeld)
    #expect(controller.phase == .idle)
  }

  @Test
  func legacySelectionEnablesTheGlobalToggle() throws {
    let suiteName = "Methamphetamine.LegacySelectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["codex"], forKey: "enabledCodingAgentIDs")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.LegacySelectionTests.\(UUID().uuidString)")
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: FakeSleepProtectionBackend(),
      startsAutomatically: false
    )

    #expect(controller.isProtectionEnabled)
    #expect(defaults.bool(forKey: "agentSleepProtectionEnabled"))
  }

  @Test
  func enabledPreferenceWaitsForPowerProtectSetupWithoutBeingLost() throws {
    let suiteName = "Methamphetamine.PendingPowerProtectTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.PendingPowerProtectTests.\(UUID().uuidString)")
    let pendingController = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: SetupSleepProtectionBackend(requiresSetup: true),
      startsAutomatically: false
    )

    #expect(!pendingController.isProtectionEnabled)
    #expect(!defaults.bool(forKey: "agentSleepProtectionEnabled"))
    #expect(defaults.bool(forKey: "pendingPowerProtectEnable"))

    let restoredController = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: SetupSleepProtectionBackend(requiresSetup: false),
      startsAutomatically: false
    )

    #expect(restoredController.isProtectionEnabled)
    #expect(defaults.bool(forKey: "agentSleepProtectionEnabled"))
    #expect(!defaults.bool(forKey: "pendingPowerProtectEnable"))
  }

  @Test
  func firstEnablePreparesPowerProtectOnce() async throws {
    let suiteName = "Methamphetamine.PowerProtectSetupTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "agentSleepProtectionEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.PowerProtectSetupTests.\(UUID().uuidString)")
    let backend = SetupSleepProtectionBackend(requiresSetup: true)
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: backend,
      startsAutomatically: false
    )

    controller.setProtectionEnabled(true)
    while controller.isPreparingProtection {
      await Task.yield()
    }

    #expect(controller.isProtectionEnabled)
    #expect(backend.prepareCount == 1)
    #expect(backend.recoverCount == 1)
    #expect(defaults.bool(forKey: "agentSleepProtectionEnabled"))
  }

  @Test
  func cancelledMigratedSetupDoesNotAutoEnableLater() async throws {
    let suiteName = "Methamphetamine.CancelledPowerProtectTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.CancelledPowerProtectTests.\(UUID().uuidString)")
    let backend = SetupSleepProtectionBackend(
      requiresSetup: true,
      prepareError: PowerProtectError.setupCancelled
    )
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: backend,
      startsAutomatically: false
    )

    #expect(defaults.bool(forKey: "pendingPowerProtectEnable"))
    controller.setProtectionEnabled(true)
    while controller.isPreparingProtection {
      await Task.yield()
    }

    #expect(!controller.isProtectionEnabled)
    #expect(!defaults.bool(forKey: "pendingPowerProtectEnable"))
  }

  @Test
  func failedRecoveryBlocksProtectionUntilCleanupSucceeds() throws {
    let suiteName = "Methamphetamine.RecoveryBlockingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.RecoveryBlockingTests.\(UUID().uuidString)")
    let backend = RecoveryBlockingSleepProtectionBackend()
    let activity = FakeCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: backend,
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )
    controller.start()

    let definition = CodingAgentDefinition(
      id: "test-agent",
      displayName: "Test Agent",
      executableNames: ["test-agent"],
      sortOrder: 0
    )
    controller.detectedAgents = [
      DetectedCodingAgent(definition: definition, isInstalled: true, isRunning: true)
    ]

    #expect(backend.acquireCount == 0)

    backend.recoveryShouldFail = false
    controller.detectedAgents = [
      DetectedCodingAgent(definition: definition, isInstalled: true, isRunning: true)
    ]

    #expect(backend.acquireCount == 1)
    #expect(backend.isHeld)
  }

  @Test
  func onlyActiveCodexTasksControlProtection() throws {
    let suiteName = "Methamphetamine.AllAgentsProtectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.AllAgentsProtectionTests.\(UUID().uuidString)")
    let backend = FakeSleepProtectionBackend()
    let activity = FakeCodexActivityProvider(snapshot: .idle)
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: backend,
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )
    let codex = CodingAgentDefinition(
      id: "codex",
      displayName: "Codex",
      executableNames: ["codex"],
      sortOrder: 0
    )
    let claude = CodingAgentDefinition(
      id: "claude",
      displayName: "Claude Code",
      executableNames: ["claude"],
      sortOrder: 1
    )

    controller.detectedAgents = [
      DetectedCodingAgent(definition: codex, isInstalled: true, isRunning: true),
      DetectedCodingAgent(definition: claude, isInstalled: true, isRunning: true),
    ]
    #expect(backend.acquireCount == 0)
    #expect(controller.phase == .idle)

    activity.snapshot = .active(turnCount: 1)
    controller.refreshCodexActivity()
    #expect(controller.phase == .protected(reason: "running_agent"))
    #expect(backend.acquireCount == 1)

    activity.snapshot = .idle
    controller.refreshCodexActivity()
    #expect(controller.phase == .idle)
    #expect(!backend.isHeld)

    activity.snapshot = .active(turnCount: 2)
    controller.refreshCodexActivity()
    #expect(controller.phase == .protected(reason: "running_agent"))
    #expect(backend.acquireCount == 2)

    controller.setProtectionEnabled(false)
    #expect(controller.phase == .idle)
    #expect(!backend.isHeld)
  }

  @Test
  func replacementTaskDoesNotPulseProtectionOffDuringGrace() throws {
    let suiteName = "Methamphetamine.ReplacementGraceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.ReplacementGraceTests.\(UUID().uuidString)")
    let backend = FakeSleepProtectionBackend()
    let activity = FakeCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: backend,
      codexActivityProvider: activity,
      protectionGraceSeconds: 3,
      startsAutomatically: false
    )

    controller.refreshCodexActivity()
    #expect(backend.acquireCount == 1)

    activity.snapshot = .idle
    controller.refreshCodexActivity()
    if case .grace = controller.phase {
      #expect(backend.isHeld)
    } else {
      Issue.record("После завершения должна начаться защитная пауза")
    }

    activity.snapshot = .active(turnCount: 1)
    controller.refreshCodexActivity()
    #expect(controller.phase == .protected(reason: "running_agent"))
    #expect(backend.acquireCount == 1)
    #expect(backend.releaseCount == 0)
    #expect(backend.renewCount == 0)
  }

  @Test
  func unavailableCodexStreamUsesFailSafeOnlyWhileToggleIsOn() throws {
    let suiteName = "Methamphetamine.ActivityFallbackTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.ActivityFallbackTests.\(UUID().uuidString)")
    let backend = FakeSleepProtectionBackend()
    let activity = FakeCodexActivityProvider(
      snapshot: .unavailable(protectConservatively: true)
    )
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: backend,
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )

    controller.refreshCodexActivity()
    #expect(backend.isHeld)
    #expect(controller.visibleError == "Не удалось точно определить задачу Codex.")

    controller.setProtectionEnabled(false)
    #expect(!backend.isHeld)
    #expect(controller.visibleError == nil)
  }

  @Test
  func disabledToggleDoesNotPollCodexSessions() throws {
    let suiteName = "Methamphetamine.DisabledActivityPollingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "agentSleepProtectionEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.DisabledActivityPollingTests.\(UUID().uuidString)")
    let activity = FakeCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: FakeSleepProtectionBackend(),
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )

    controller.start()
    #expect(activity.refreshCount == 0)

    controller.setProtectionEnabled(true)
    #expect(activity.refreshCount == 1)
    controller.refreshCodexActivity()
    #expect(activity.refreshCount == 2)

    controller.setProtectionEnabled(false)
    #expect(activity.resetCount == 1)
  }

  @Test
  func failedReleaseRetriesWhileProtectionIsOffWithoutPollingCodex() throws {
    let suiteName = "Methamphetamine.ReleaseRetryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.ReleaseRetryTests.\(UUID().uuidString)")
    let backend = TransientReleaseFailureBackend()
    let activity = FakeCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: backend,
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )

    controller.refreshCodexActivity()
    #expect(backend.isHeld)

    backend.failNextRelease = true
    controller.setProtectionEnabled(false)
    #expect(backend.isHeld)
    #expect(backend.releaseAttempts == 1)
    #expect(controller.visibleError != nil)
    #expect(activity.resetCount == 1)

    let refreshCount = activity.refreshCount
    controller.tick()

    #expect(!backend.isHeld)
    #expect(backend.releaseAttempts == 2)
    #expect(controller.visibleError == nil)
    #expect(activity.refreshCount == refreshCount)
  }

  @Test
  func lowBatterySleepReleasesAndRestoresProtectionAtStrictThreshold() throws {
    let suiteName = "Methamphetamine.LowBatterySleepTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")
    defaults.set(true, forKey: "lowBatterySleepEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.LowBatterySleepTests.\(UUID().uuidString)")
    let backend = FakeSleepProtectionBackend()
    let battery = FakeBatteryStatusProvider(
      status: BatteryStatus(chargePercent: 50, isRunningOnBattery: true)
    )
    let activity = FakeCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: backend,
      batteryStatusProvider: battery,
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )
    let runningAgent = DetectedCodingAgent(
      definition: CodingAgentDefinition(
        id: "test-agent",
        displayName: "Test Agent",
        executableNames: ["test-agent"],
        sortOrder: 0
      ),
      isInstalled: true,
      isRunning: true
    )

    controller.detectedAgents = [runningAgent]
    #expect(backend.isHeld)
    #expect(backend.acquireCount == 1)

    battery.status = BatteryStatus(chargePercent: 9, isRunningOnBattery: true)
    controller.detectedAgents = [runningAgent]
    #expect(!backend.isHeld)
    #expect(backend.releaseCount == 1)

    battery.status = BatteryStatus(chargePercent: 10, isRunningOnBattery: true)
    controller.detectedAgents = [runningAgent]
    #expect(backend.isHeld)
    #expect(backend.acquireCount == 2)
  }

  @Test
  func lowChargeDoesNotReleaseProtectionOnExternalPowerOrWhenUnknown() throws {
    let suiteName = "Methamphetamine.LowBatteryExternalPowerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")
    defaults.set(true, forKey: "lowBatterySleepEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.LowBatteryExternalPowerTests.\(UUID().uuidString)")
    let backend = FakeSleepProtectionBackend()
    let battery = FakeBatteryStatusProvider(
      status: BatteryStatus(chargePercent: 9, isRunningOnBattery: false)
    )
    let activity = FakeCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: backend,
      batteryStatusProvider: battery,
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )
    let runningAgent = DetectedCodingAgent(
      definition: CodingAgentDefinition(
        id: "test-agent",
        displayName: "Test Agent",
        executableNames: ["test-agent"],
        sortOrder: 0
      ),
      isInstalled: true,
      isRunning: true
    )

    controller.detectedAgents = [runningAgent]
    #expect(backend.isHeld)

    battery.status = nil
    controller.detectedAgents = [runningAgent]
    #expect(backend.isHeld)
    #expect(backend.releaseCount == 0)
  }

  @Test
  func lowBatteryToggleImmediatelyReevaluatesAndPersists() throws {
    let suiteName = "Methamphetamine.LowBatteryToggleTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")
    defaults.set(true, forKey: "lowBatterySleepEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory
      .appending(path: "Methamphetamine.LowBatteryToggleTests.\(UUID().uuidString)")
    let backend = FakeSleepProtectionBackend()
    let battery = FakeBatteryStatusProvider(
      status: BatteryStatus(chargePercent: 9, isRunningOnBattery: true)
    )
    let activity = FakeCodexActivityProvider(snapshot: .active(turnCount: 1))
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: backend,
      batteryStatusProvider: battery,
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false
    )
    controller.detectedAgents = [
      DetectedCodingAgent(
        definition: CodingAgentDefinition(
          id: "test-agent",
          displayName: "Test Agent",
          executableNames: ["test-agent"],
          sortOrder: 0
        ),
        isInstalled: true,
        isRunning: true
      )
    ]

    #expect(!backend.isHeld)
    controller.setLowBatterySleepEnabled(false)
    #expect(backend.isHeld)
    #expect(!defaults.bool(forKey: "lowBatterySleepEnabled"))

    controller.setLowBatterySleepEnabled(true)
    #expect(!backend.isHeld)
    #expect(defaults.bool(forKey: "lowBatterySleepEnabled"))
  }
}

@MainActor
private final class FakeSleepProtectionBackend: SleepProtectionBackend {
  let identifier = "fake"
  private(set) var isHeld = false
  private(set) var acquireCount = 0
  private(set) var releaseCount = 0
  private(set) var renewCount = 0

  func acquire() throws {
    acquireCount += 1
    isHeld = true
  }

  func renew() throws {
    renewCount += 1
  }

  func release() {
    releaseCount += 1
    isHeld = false
  }
}

private final class FakeBatteryStatusProvider: BatteryStatusProviding {
  var status: BatteryStatus?

  init(status: BatteryStatus?) {
    self.status = status
  }

  func currentStatus() -> BatteryStatus? {
    status
  }
}

private final class FakeCodexActivityProvider: CodexActivityProviding {
  var snapshot: CodexActivitySnapshot
  private(set) var refreshCount = 0
  private(set) var resetCount = 0

  init(snapshot: CodexActivitySnapshot) {
    self.snapshot = snapshot
  }

  func refresh() -> CodexActivitySnapshot {
    refreshCount += 1
    return snapshot
  }

  func reset() {
    resetCount += 1
  }
}

@MainActor
private final class TransientReleaseFailureBackend: SleepProtectionBackend {
  let identifier = "release-retry-fake"
  private(set) var isHeld = false
  private(set) var releaseAttempts = 0
  var failNextRelease = false

  func acquire() throws {
    isHeld = true
  }

  func renew() throws {}

  func release() throws {
    releaseAttempts += 1
    if failNextRelease {
      failNextRelease = false
      throw TestReleaseError.transientFailure
    }
    isHeld = false
  }
}

private enum TestReleaseError: Error {
  case transientFailure
}

@MainActor
private final class SetupSleepProtectionBackend: SleepProtectionBackend {
  let identifier = "setup-fake"
  private(set) var isHeld = false
  private(set) var prepareCount = 0
  private(set) var recoverCount = 0
  var requiresSetup: Bool
  private let prepareError: Error?

  init(requiresSetup: Bool, prepareError: Error? = nil) {
    self.requiresSetup = requiresSetup
    self.prepareError = prepareError
  }

  func prepare() async throws {
    prepareCount += 1
    await Task.yield()
    if let prepareError { throw prepareError }
    requiresSetup = false
  }

  func recover() throws {
    recoverCount += 1
  }

  func acquire() throws {
    isHeld = true
  }

  func renew() throws {}

  func release() {
    isHeld = false
  }
}

@MainActor
private final class RecoveryBlockingSleepProtectionBackend: SleepProtectionBackend {
  let identifier = "recovery-blocking-fake"
  private(set) var isHeld = true
  private(set) var acquireCount = 0
  var recoveryShouldFail = true

  func recover() throws {
    if recoveryShouldFail { throw PowerProtectError.restoreFailed }
    isHeld = false
  }

  func acquire() throws {
    acquireCount += 1
    isHeld = true
  }

  func renew() throws {}

  func release() {
    isHeld = false
  }
}
