import AppKit
import Combine
import Foundation
import MethamphetamineCore
import MethamphetamineUI

@MainActor
final class AppController: NSObject, ObservableObject {
  private static let legacyMigrationVersion = 2
  private static let legacyMigrationVersionKey = "legacyHookMigrationVersion"
  private static let activityRefreshInterval: TimeInterval = 1
  private static let backendRenewInterval: TimeInterval = 30
  static let lowBatterySleepThresholdPercent = 10.0

  @Published private(set) var isProtectionEnabled: Bool
  @Published private(set) var isPreparingProtection = false
  @Published private(set) var isResolvingIssue = false
  @Published private(set) var phase: ProtectionPhase = .idle
  @Published private(set) var menuIssue: MenuIssue?

  var detectedAgents: [DetectedCodingAgent] = [] {
    didSet { evaluateProtection() }
  }

  private let defaults: UserDefaults
  private let protectionStore: AgentProtectionStore
  private let legacyIntegrations: LegacyIntegrationMigrator
  private let backend: SleepProtectionBackend
  private let batteryStatusProvider: BatteryStatusProviding
  private let codexActivityProvider: CodexActivityProviding
  private let launchAtLoginController: any LaunchAtLoginControlling
  private let protectionGraceSeconds: TimeInterval
  private var codexActivitySnapshot: CodexActivitySnapshot
  private var policy: SleepPolicyMachine
  private var timer: Timer?
  private var activityToken: NSObjectProtocol?
  private var lastBackendRenewAt = Date.distantPast
  private var started = false
  private var recoveryPending = false

  override convenience init() {
    self.init(startsAutomatically: true)
  }

  convenience init(startsAutomatically: Bool) {
    self.init(
      defaults: .standard,
      detector: CodingAgentSystemScanner(),
      legacyIntegrations: LegacyIntegrationMigrator(),
      backend: CombinedSleepProtectionBackend(
        idleSleep: IdleSleepAssertionBackend(),
        closedLid: PMSetPowerProtectBackend()
      ),
      batteryStatusProvider: IOKitBatteryStatusProvider(),
      codexActivityProvider: CodexSessionActivityMonitor(),
      launchAtLoginController: LaunchAtLoginController(),
      startsAutomatically: startsAutomatically
    )
  }

  init(
    defaults: UserDefaults,
    detector _: CodingAgentSystemScanner,
    legacyIntegrations: LegacyIntegrationMigrator,
    backend: SleepProtectionBackend,
    batteryStatusProvider: BatteryStatusProviding = IOKitBatteryStatusProvider(),
    codexActivityProvider: CodexActivityProviding = CodexSessionActivityMonitor(),
    launchAtLoginController: any LaunchAtLoginControlling = NoOpLaunchAtLoginController(),
    protectionGraceSeconds: TimeInterval = 15,
    startsAutomatically: Bool
  ) {
    let protectionStore = AgentProtectionStore(defaults: defaults)
    let storedPreference = protectionStore.load()
    let pendingSetup = protectionStore.isPowerProtectSetupPending
    let isProtectionEnabled: Bool
    if backend.requiresSetup && (storedPreference || pendingSetup) {
      protectionStore.markPowerProtectSetupPending()
      isProtectionEnabled = false
    } else if !backend.requiresSetup && pendingSetup {
      protectionStore.clearPowerProtectSetupPending()
      isProtectionEnabled = true
    } else {
      isProtectionEnabled = storedPreference
    }
    if !protectionStore.hasStoredPreference || storedPreference != isProtectionEnabled {
      protectionStore.save(isProtectionEnabled)
    }

    self.defaults = defaults
    self.protectionStore = protectionStore
    self.legacyIntegrations = legacyIntegrations
    self.backend = backend
    self.batteryStatusProvider = batteryStatusProvider
    self.codexActivityProvider = codexActivityProvider
    self.launchAtLoginController = launchAtLoginController
    self.protectionGraceSeconds = protectionGraceSeconds
    codexActivitySnapshot = codexActivityProvider.snapshot
    self.isProtectionEnabled = isProtectionEnabled
    policy = SleepPolicyMachine(
      config: SleepPolicyConfig(
        autoMode: true,
        graceSeconds: protectionGraceSeconds
      )
    )

    super.init()

    if startsAutomatically {
      Task { @MainActor [weak self] in
        self?.start()
      }
    }
  }

  var visibleError: String? {
    menuIssue?.title
  }

  var statusTitle: String {
    if let menuIssue { return menuIssue.title }
    if isPreparingProtection { return "Setting up sleep protection" }
    if !isProtectionEnabled { return "Sleep protection is off" }

    switch phase {
    case .idle:
      return "Waiting"
    case .protected:
      return "Preventing sleep"
    case .grace:
      return "Finishing up"
    }
  }

  var showsMenuIssue: Bool {
    menuIssue != nil
  }

  func start() {
    guard !started else { return }
    started = true

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillTerminate),
      name: NSApplication.willTerminateNotification,
      object: nil
    )

    do {
      try backend.recover()
      recoveryPending = false
      menuIssue = nil
    } catch {
      recoveryPending = true
      menuIssue = .sleepRestoreRequired
      logHiddenError("recover sleep", error: error)
    }

    migrateLegacyIntegrations()
    if let launchAtLoginError = launchAtLoginController.enableByDefault() {
      NSLog("Methamphetamine launch-at-login issue: %@", launchAtLoginError)
    }
    if isProtectionEnabled {
      refreshCodexActivity()
    }

    activityToken = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "Monitor Codex task activity"
    )
    let activityTimer = Timer(
      timeInterval: Self.activityRefreshInterval,
      repeats: true
    ) { [weak self] _ in
      Task { @MainActor in
        self?.tick()
      }
    }
    activityTimer.tolerance = 0.2
    RunLoop.main.add(activityTimer, forMode: .common)
    timer = activityTimer
  }

  func menuDidOpen() {
    if started, isProtectionEnabled {
      refreshCodexActivity()
    } else if !started {
      start()
    }
  }

  func tick() {
    guard isProtectionEnabled else {
      if backend.isHeld || recoveryPending {
        evaluateProtection()
      }
      return
    }
    refreshCodexActivity()
  }

  func refreshCodexActivity() {
    codexActivitySnapshot = codexActivityProvider.refresh()
    evaluateProtection()
  }

  func setProtectionEnabled(_ isEnabled: Bool) {
    if !isEnabled {
      protectionStore.clearPowerProtectSetupPending()
      applyProtectionPreference(false)
      return
    }
    guard !isProtectionEnabled, !isPreparingProtection else { return }

    if backend.requiresSetup {
      isPreparingProtection = true
      menuIssue = nil
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          try await backend.prepare()
          guard !backend.requiresSetup else {
            throw PowerProtectError.setupVerificationFailed
          }
          try backend.recover()
          recoveryPending = false
          protectionStore.clearPowerProtectSetupPending()
          isPreparingProtection = false
          applyProtectionPreference(true)
        } catch {
          isPreparingProtection = false
          let setupWasCancelled =
            (error as? PowerProtectError) == .setupCancelled
          if setupWasCancelled {
            protectionStore.clearPowerProtectSetupPending()
          }
          applyProtectionPreference(false)
          menuIssue = setupWasCancelled ? nil : .permissionRequired
          if !setupWasCancelled {
            logHiddenError("configure closed-lid protection", error: error)
          }
        }
      }
    } else {
      protectionStore.clearPowerProtectSetupPending()
      applyProtectionPreference(true)
    }
  }

  func resolveMenuIssue() {
    guard let menuIssue, !isResolvingIssue else { return }
    switch menuIssue {
    case .permissionRequired:
      setProtectionEnabled(true)
    case .sleepRestoreRequired:
      restoreSleepFromMenu()
    }
  }

  private func applyProtectionPreference(_ isEnabled: Bool) {
    isProtectionEnabled = isEnabled
    protectionStore.save(isEnabled)
    if isEnabled {
      menuIssue = nil
      refreshCodexActivity()
    } else {
      codexActivityProvider.reset()
      codexActivitySnapshot = .idle
      policy = SleepPolicyMachine(
        config: SleepPolicyConfig(
          autoMode: true,
          graceSeconds: protectionGraceSeconds
        )
      )
      do {
        try backend.release()
        lastBackendRenewAt = .distantPast
        recoveryPending = false
        menuIssue = nil
      } catch {
        menuIssue = .sleepRestoreRequired
        logHiddenError("restore sleep after disabling protection", error: error)
      }
      phase = .idle
    }
  }

  private func evaluateProtection() {
    if recoveryPending {
      do {
        try backend.recover()
        recoveryPending = false
        menuIssue = nil
      } catch {
        phase = .idle
        menuIssue = .sleepRestoreRequired
        logHiddenError("retry sleep recovery", error: error)
        return
      }
    }

    let shouldAllowSleepForLowBattery =
      batteryStatusProvider.currentStatus()?.isAtOrBelow(
        Self.lowBatterySleepThresholdPercent
      ) ?? false
    if !isProtectionEnabled || shouldAllowSleepForLowBattery {
      policy = SleepPolicyMachine(
        config: SleepPolicyConfig(
          autoMode: true,
          graceSeconds: protectionGraceSeconds
        )
      )
      if backend.isHeld {
        do {
          try backend.release()
          lastBackendRenewAt = .distantPast
          recoveryPending = false
          menuIssue = nil
        } catch {
          menuIssue = .sleepRestoreRequired
          logHiddenError("restore sleep", error: error)
        }
      }
      phase = .idle
      return
    }

    let activeCount = codexActivitySnapshot.effectiveActiveCount
    let wasHeld = backend.isHeld
    let now = Date.now
    phase = policy.evaluate(activeCount: activeCount)

    if policy.shouldProtect {
      do {
        if wasHeld {
          if now.timeIntervalSince(lastBackendRenewAt) >= Self.backendRenewInterval {
            try backend.renew()
            lastBackendRenewAt = now
          }
        } else {
          try backend.acquire()
          lastBackendRenewAt = now
        }
        menuIssue = nil
      } catch {
        let activationError = error
        do {
          try backend.release()
          lastBackendRenewAt = .distantPast
          if (activationError as? PowerProtectError) == .setupRequired {
            menuIssue = .permissionRequired
          } else {
            menuIssue = nil
            logHiddenError("activate protection", error: activationError)
          }
        } catch {
          menuIssue = .sleepRestoreRequired
          logHiddenError("restore sleep after activation failure", error: error)
        }
      }
    } else {
      if wasHeld {
        do {
          try backend.release()
          lastBackendRenewAt = .distantPast
          recoveryPending = false
          menuIssue = nil
        } catch {
          menuIssue = .sleepRestoreRequired
          logHiddenError("restore sleep after task completion", error: error)
        }
      }
    }
  }

  func migrateLegacyIntegrations() {
    guard
      defaults.integer(forKey: Self.legacyMigrationVersionKey)
        < Self.legacyMigrationVersion
    else { return }

    var failures: [String] = []

    for integration in IntegrationKind.allCases where legacyIntegrations.isInstalled(integration) {
      do {
        try legacyIntegrations.remove(integration)
      } catch {
        let name = integration == .codex ? "Codex" : "Claude"
        failures.append(name)
      }
    }

    if failures.isEmpty {
      defaults.set(Self.legacyMigrationVersion, forKey: Self.legacyMigrationVersionKey)
    } else {
      NSLog(
        "Methamphetamine could not remove legacy integrations: %@",
        failures.joined(separator: ", ")
      )
    }
  }

  private func restoreSleepFromMenu() {
    isResolvingIssue = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { isResolvingIssue = false }
      do {
        if backend.requiresSetup {
          try await backend.prepare()
        }
        try backend.release()
        recoveryPending = false
        lastBackendRenewAt = .distantPast
        menuIssue = nil
      } catch {
        menuIssue = .sleepRestoreRequired
        logHiddenError("restore sleep from menu", error: error)
      }
    }
  }

  private func logHiddenError(_ operation: String, error: Error) {
    NSLog("Methamphetamine failed to %@: %@", operation, error.localizedDescription)
  }

  @objc
  private func applicationWillTerminate() {
    shutdown()
  }

  private func shutdown() {
    guard started else { return }
    started = false
    timer?.invalidate()
    timer = nil
    if let activityToken {
      ProcessInfo.processInfo.endActivity(activityToken)
      self.activityToken = nil
    }
    do {
      try backend.release()
    } catch {
      NSLog("Methamphetamine failed to restore sleep: %@", error.localizedDescription)
    }
    NotificationCenter.default.removeObserver(self)
  }
}
